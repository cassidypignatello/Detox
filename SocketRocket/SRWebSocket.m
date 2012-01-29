//
//   Copyright 2012 Square Inc.
//
//   Licensed under the Apache License, Version 2.0 (the "License");
//   you may not use this file except in compliance with the License.
//   You may obtain a copy of the License at
//
//       http://www.apache.org/licenses/LICENSE-2.0
//
//   Unless required by applicable law or agreed to in writing, software
//   distributed under the License is distributed on an "AS IS" BASIS,
//   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//   See the License for the specific language governing permissions and
//   limitations under the License.
//


#import "SRWebSocket.h"

#import <unicode/utf8.h>
#import <endian.h>
#import <CommonCrypto/CommonDigest.h>

#import "base64.h"

typedef enum  {
    SROpCodeTextFrame = 0x1,
    SROpCodeBinaryFrame = 0x2,
    //3-7Reserved 
    SROpCodeConnectionClose = 0x8,
    SROpCodePing = 0x9,
    SROpCodePong = 0xA,
    //B-F reserved
} SROpCode;

typedef enum {
    SRStatusCodeNormal = 1000,
    SRStatusCodeGoingAway = 1001,
    SRStatusCodeProtocolError = 1002,
    SRStatusCodeUnhandledType = 1003,
    // 1004 reserved
    SRStatusNoStatusReceived = 1005,
    // 1004-1006 reserved
    SRStatusCodeInvalidUTF8 = 1007,
    SRStatusCodePolicyViolated = 1008,
    SRStatusCodeMessageTooBig = 1009,
} SRStatusCode;

typedef struct {
    BOOL fin;
//  BOOL rsv1;
//  BOOL rsv2;
//  BOOL rsv3;
    uint8_t opcode;
    BOOL masked;
    uint64_t payload_length;
} frame_header;


static inline dispatch_queue_t log_queue() {

    static dispatch_queue_t queue = 0;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("fast log queue", DISPATCH_QUEUE_SERIAL);
    });
    
    return queue;
}

static inline void SRFastLog(NSString *format, ...)  {
    
#if 1
    __block va_list arg_list;
    va_start (arg_list, format);
    
    NSString *formattedString = [[NSString alloc] initWithFormat:format arguments:arg_list];
    
    va_end(arg_list);
    
    NSLog(@"SR %@", formattedString);
#endif
}

static NSString *const strAppendForAuth = @"258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

static inline int32_t validate_dispatch_data_partial_string(NSData *data) {
    
    const void * contents = [data bytes];
    long size = [data length];
    
    const uint8_t *str = (const uint8_t *)contents;

    
    UChar32 codepoint = 1;
    int32_t offset = 0;
    int32_t lastOffset = 0;
    while(offset < size && codepoint > 0)  {
        lastOffset = offset;
        U8_NEXT(str, offset, size, codepoint);
    }
    
    if (codepoint == -1) {
        // Check to see if the last byte is valid or whether it was just continuing
        if (!U8_IS_LEAD(str[lastOffset]) || U8_COUNT_TRAIL_BYTES(str[lastOffset]) + lastOffset < (int32_t)size) {
            
            size = -1;
        } else {
            uint8_t leadByte = str[lastOffset];
            U8_MASK_LEAD_BYTE(leadByte, U8_COUNT_TRAIL_BYTES(leadByte));

            for (int i = lastOffset + 1; i < offset; i++) {
                
                if (U8_IS_SINGLE(str[i]) || U8_IS_LEAD(str[i]) || !U8_IS_TRAIL(str[i])) {
                    size = -1;
                }
            }
                 
            if (size != -1) {
                size = lastOffset;
            }
        }
    }

    if (size != -1 && ![[NSString alloc] initWithBytesNoCopy:(char *)[data bytes] length:size encoding:NSUTF8StringEncoding freeWhenDone:NO]) {
        size = -1;
    }
    
    return size;
}


@interface NSString (DispatchDataAdditions)

- (NSString *)stringBySHA1ThenBase64Encoding;

@end

#define CONSERVATIVE_COPY

@implementation NSString (DispatchDataAdditions)

- (NSString *)stringBySHA1ThenBase64Encoding;
{
    uint8_t md[CC_SHA1_DIGEST_LENGTH];
    
    CC_SHA1([self UTF8String], [self lengthOfBytesUsingEncoding:NSUTF8StringEncoding], md);

    size_t buffer_size = ((sizeof(md) * 3 + 2) / 2);
    
    char *buffer =  (char *)malloc(buffer_size);
    
    int len = b64_ntop(md, CC_SHA1_DIGEST_LENGTH, buffer, buffer_size);
    if (len == -1) {
        free(buffer);
        return nil;
    } else{
        return [[NSString alloc] initWithBytesNoCopy:buffer length:len encoding:NSASCIIStringEncoding freeWhenDone:YES];
    }
}

@end

NSString *const SRWebSocketErrorDomain = @"SRWebSocketErrorDomain";

// Returns number of bytes consumed. returning 0 means you didn't match.
// Sends bytes to callback handler;
typedef size_t (^stream_scanner)(NSData *collected_data);

typedef void (^data_callback)(SRWebSocket *webSocket,  NSData *data);

@interface SRIOConsumer : NSObject {
    stream_scanner _scanner;
    data_callback _handler;
    size_t _bytesNeeded;
    BOOL _readToCurrentFrame;
    BOOL _unmaskBytes;
}

- (id)initWithScanner:(stream_scanner)scanner handler:(data_callback)handler bytesNeeded:(size_t)bytesNeeded readToCurrentFrame:(BOOL)readToCurrentFrame unmaskBytes:(BOOL)unmaskBytes;

@property (nonatomic, copy, readonly) stream_scanner consumer;
@property (nonatomic, copy, readonly) data_callback handler;
@property (nonatomic, assign) size_t bytesNeeded;
@property (nonatomic, assign, readonly) BOOL readToCurrentFrame;
@property (nonatomic, assign, readonly) BOOL unmaskBytes;

@end


@interface SRWebSocket ()  <NSStreamDelegate>

- (void)_writeData:(NSData *)data;
- (void)_closeWithProtocolError:(NSString *)message;
- (void)_failWithError:(NSError *)error;

- (void)_disconnect;

- (void)_readFrameNew;
- (void)_readFrameContinue;

- (void)_pumpScanner;

- (void)_pumpWriting;

- (void)_addConsumerWithScanner:(stream_scanner)consumer callback:(data_callback)callback;
- (void)_addConsumerWithDataLength:(size_t)dataLength callback:(data_callback)callback readToCurrentFrame:(BOOL)readToCurrentFrame unmaskBytes:(BOOL)unmaskBytes;
- (void)_addConsumerWithScanner:(stream_scanner)consumer callback:(data_callback)callback dataLength:(size_t)dataLength;
- (void)_readUntilBytes:(const void *)bytes length:(size_t)length callback:(data_callback)dataHandler;
- (void)_readUntilHeaderCompleteWithCallback:(data_callback)dataHandler;

- (void)_sendFrameWithOpcode:(SROpCode)opcode data:(id)data;

- (void)_checkHandshake:(NSDictionary *)headers;
- (void)_SR_commonInit;

+ (dispatch_queue_t)globalReadQueue;

@property (nonatomic) SRReadyState readyState;

@end


@implementation SRWebSocket {
    NSInteger _webSocketVersion;
    dispatch_queue_t _callbackQueue;
    dispatch_queue_t _workQueue;
    NSMutableArray *_consumers;

    NSInputStream *_inputStream;
    NSOutputStream *_outputStream;
   
    NSMutableData *_readBuffer;
    NSInteger _readBufferOffset;
 
    NSMutableData *_outputBuffer;
    NSInteger _outputBufferOffset;

    uint8_t _currentFrameOpcode;
    size_t _currentFrameCount;
    size_t _readOpCount;
    uint32_t _currentStringScanPosition;
    NSMutableData *_currentFrameData;
    
    uint8_t _currentReadMaskKey[4];
    size_t _currentReadMaskOffset;

    BOOL _consumerStopped;
    
    BOOL _closeWhenFinishedWriting;
    
    BOOL _secure;
    NSURLRequest *_urlRequest;

    __attribute__((NSObject)) CFHTTPMessageRef _receivedHTTPHeaders;
    
    BOOL _didFail;
    int _closeCode;
}

@synthesize delegate = _delegate;
@synthesize url = _url;
@synthesize readyState = _readyState;

@synthesize onOpen = _onOpen;
@synthesize onClose = _onClose;
@synthesize onMessage = _onMessage;
@synthesize onError = _onError;

static __strong NSData *CRLFCRLF;

+ (void)initialize;
{
    CRLFCRLF = [[NSData alloc] initWithBytes:"\r\n\r\n" length:4];
}

+ (dispatch_queue_t)globalReadQueue;
{
    static dispatch_queue_t globalQueue = nil;
    static dispatch_once_t token;
    
    dispatch_once(&token, ^{
        globalQueue = dispatch_queue_create("org.lolrus.socket.globalQueue", DISPATCH_QUEUE_SERIAL);
    });
    
    return globalQueue;
}

- (id)initWithURLRequest:(NSURLRequest *)request;
{
    self = [super init];
    if (self) {
        
        assert(request.URL);
        _url = request.URL;
        NSString *scheme = [_url scheme];
        
        assert([scheme isEqualToString:@"ws"] || [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"wss"] || [scheme isEqualToString:@"https"]);
        _urlRequest = request;
        
        if ([scheme isEqualToString:@"wss"] || [scheme isEqualToString:@"https"]) {
            _secure = YES;
        }
        
        [self _SR_commonInit];
    }
    
    return self;
}

- (void)_SR_commonInit;
{
    _readyState = SR_CONNECTING;

    _consumerStopped = YES;
    
    _webSocketVersion = 13;
    
    _workQueue = dispatch_queue_create(NULL, DISPATCH_QUEUE_SERIAL);
    
    _callbackQueue = dispatch_get_main_queue();
    dispatch_retain(_callbackQueue);
    
    _readBuffer = [[NSMutableData alloc] init];
    _outputBuffer = [[NSMutableData alloc] init];
    
    _currentFrameData = [[NSMutableData alloc] init];

    _consumers = [[NSMutableArray alloc] init];
    
    // default handlers
    self.onError = ^(SRWebSocket *webSocket, NSError *error) {
        if ([webSocket.delegate respondsToSelector:@selector(webSocket:didFailWithError:)]) {
            [webSocket.delegate webSocket:webSocket didFailWithError:error];
        }
    };
    
    self.onMessage = ^(SRWebSocket *webSocket, id message) {
        if ([webSocket.delegate respondsToSelector:@selector(webSocket:didReceiveMessage:)]) {
            [webSocket.delegate webSocket:webSocket didReceiveMessage:message];
        }
    };
    
    self.onClose = ^(SRWebSocket *webSocket, NSInteger code, NSString *reason, BOOL wasClean) {
        if ([webSocket.delegate respondsToSelector:@selector(webSocket:didCloseWithCode:reason:wasClean:)]) {
            [webSocket.delegate webSocket:webSocket didCloseWithCode:code reason:reason wasClean:wasClean];
        }
    };
    
    self.onOpen = ^(SRWebSocket *webSocket) {
        if ([webSocket.delegate respondsToSelector:@selector(webSocketDidOpen:)]) {
            [webSocket.delegate webSocketDidOpen:webSocket];
        }
    };
}

- (void)dealloc
{    
    dispatch_release(_callbackQueue);
    dispatch_release(_workQueue);
    _inputStream.delegate = nil;
    _outputStream.delegate = nil;
}

#ifndef NDEBUG

- (void)setReadyState:(SRReadyState)aReadyState;
{
    [self willChangeValueForKey:@"readyState"];
    assert(aReadyState > _readyState);
    _readyState = aReadyState;
    [self didChangeValueForKey:@"readyState"];
}

#endif

- (void)open {
    assert(_url);

    NSInteger port = _url.port.integerValue;
    if (port == 0) {
        if (!_secure) {
            port = 80;
        } else {
            port = 443;
        }
    }

    [self connectToHost:_url.host port:port];
}



- (void)_checkHandshake:(NSDictionary *)headers;
{
    SRFastLog(@"TODO: Add handshake checking");
}

- (void)_HTTPHeadersDidFinish;
{
    NSDictionary *dict = CFBridgingRelease(CFHTTPMessageCopyAllHeaderFields(_receivedHTTPHeaders));

    [self _checkHandshake:dict];
    NSInteger responseCode = CFHTTPMessageGetResponseStatusCode(_receivedHTTPHeaders);
    
    if (responseCode >= 400) {
        SRFastLog(@"Request failed with response code %d", responseCode);
        [self failWithError:[NSError errorWithDomain:@"org.lolrus.SocketRocket" code:2132 userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:@"received bad response code from server %d", responseCode] forKey:NSLocalizedDescriptionKey]]];
        return;

    }
    
    self.readyState = SR_OPEN;
    
    if (!_didFail) {
        [self _readFrameNew];
    }

    dispatch_async(_callbackQueue, ^{
        self.onOpen(self);
    });
}


- (void)_readHTTPHeader;
{
    if (_receivedHTTPHeaders == NULL) {
        _receivedHTTPHeaders = CFHTTPMessageCreateEmpty(NULL, NO);
    }
                        
    [self _readUntilHeaderCompleteWithCallback:^(SRWebSocket *self,  NSData *data) {
        CFHTTPMessageAppendBytes(_receivedHTTPHeaders, (const UInt8 *)data.bytes, data.length);
        
        if (CFHTTPMessageIsHeaderComplete(_receivedHTTPHeaders)) {
            SRFastLog(@"Finished reading headers %@", CFBridgingRelease(CFHTTPMessageCopyAllHeaderFields(_receivedHTTPHeaders)));
            [self _HTTPHeadersDidFinish];
        } else {
            [self _readHTTPHeader];
        }
    }];
}

- (void)didConnect
{
    SRFastLog(@"Connected");
    CFHTTPMessageRef request = CFHTTPMessageCreateRequest(NULL, CFSTR("GET"), (__bridge CFURLRef)_url, kCFHTTPVersion1_1);
    
    // Set host first so it defaults
    CFHTTPMessageSetHeaderFieldValue(request, CFSTR("Host"), (__bridge CFStringRef)(_url.port ? [NSString stringWithFormat:@"%@:%@", _url.host, _url.port] : _url.host));
    
    [_urlRequest.allHTTPHeaderFields enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        CFHTTPMessageSetHeaderFieldValue(request, (__bridge CFStringRef)key, (__bridge CFStringRef)obj);
    }];
    
    CFHTTPMessageSetHeaderFieldValue(request, CFSTR("Upgrade"), CFSTR("websocket"));
    CFHTTPMessageSetHeaderFieldValue(request, CFSTR("Connection"), CFSTR("Upgrade"));
    CFHTTPMessageSetHeaderFieldValue(request, CFSTR("Sec-WebSocket-Key"), CFSTR("/PiDVHFKG9+oB7rLAudvxw=="));
    CFHTTPMessageSetHeaderFieldValue(request, CFSTR("Sec-WebSocket-Version"), (__bridge CFStringRef)[NSString stringWithFormat:@"%d", _webSocketVersion]);
    CFHTTPMessageSetHeaderFieldValue(request, CFSTR("Origin"), (__bridge CFStringRef)_url.absoluteString);
    
    NSData *message = CFBridgingRelease(CFHTTPMessageCopySerializedMessage(request));
    
    CFRelease(request);

    [self _writeData:message];
    [self _readHTTPHeader];
}

- (void)connectToHost:(NSString *)host port:(NSInteger)port;
{    
    CFReadStreamRef readStream = NULL;
    CFWriteStreamRef writeStream = NULL;
    
    CFStreamCreatePairWithSocketToHost(NULL, (__bridge CFStringRef)host, port, &readStream, &writeStream);
    
    _outputStream = CFBridgingRelease(writeStream);
    _inputStream = CFBridgingRelease(readStream);
    
    if (_secure) {
        [_outputStream setProperty:(__bridge id)kCFStreamSocketSecurityLevelNegotiatedSSL forKey:(__bridge id)kCFStreamPropertySocketSecurityLevel];
        #if DEBUG
        NSLog(@"SocketRocket: In debug mode.  Allowing connection to any root cert");
        [_outputStream setProperty:[NSDictionary dictionaryWithObject:[NSNumber numberWithBool:YES] 
                                                               forKey:(__bridge id)kCFStreamSSLAllowsAnyRoot]
                            forKey:(__bridge id)kCFStreamPropertySSLSettings];
        #endif
    }
    
    _inputStream.delegate = self;
    _outputStream.delegate = self;
    
    // TODO schedule in a better run loop
    [_outputStream scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
    [_inputStream scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
    
    
    [_outputStream open];
    [_inputStream open];
}

- (void)close;
{
    [self closeWithCode:-1 reason:nil];
}

- (void)closeWithCode:(NSInteger)code reason:(NSString *)reason;
{
    assert(code);
    if (self.readyState == SR_CLOSING || self.readyState == SR_CLOSED) {
        return;
    }
    
    BOOL wasConnecting = self.readyState == SR_CONNECTING;

    self.readyState = SR_CLOSING;

    SRFastLog(@"Closing with code %d reason %@", code, reason);
    dispatch_async(_workQueue, ^{
        if (wasConnecting) {
            [self _disconnect];
            return;
        }

        size_t maxMsgSize = [reason maximumLengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        NSMutableData *mutablePayload = [[NSMutableData alloc] initWithLength:sizeof(uint16_t) + maxMsgSize];
        NSData *payload = mutablePayload;
        
        ((uint16_t *)mutablePayload.mutableBytes)[0] = EndianU16_BtoN(code);
        
        if (reason) {
            NSRange remainingRange = {0};
            
            NSUInteger usedLength = 0;
            
            BOOL success = [reason getBytes:(char *)mutablePayload.mutableBytes + sizeof(uint16_t) maxLength:payload.length - sizeof(uint16_t) usedLength:&usedLength encoding:NSUTF8StringEncoding options:NSStringEncodingConversionExternalRepresentation range:NSMakeRange(0, reason.length) remainingRange:&remainingRange];
            
            assert(success);
            assert(remainingRange.length == 0);

            if (usedLength != maxMsgSize) {
                payload = [payload subdataWithRange:NSMakeRange(0, usedLength + sizeof(uint16_t))];
            }
        }
        
        
        [self _sendFrameWithOpcode:SROpCodeConnectionClose data:payload];
    });
}

- (void)failWithError:(NSError *)error;
{
    [self _failWithError:error];
}

- (void)_closeWithProtocolError:(NSString *)message;
{
    [self closeWithCode:SRStatusCodeProtocolError reason:message];
    dispatch_async(_workQueue, ^{
        [self _disconnect];
    });
}

- (void)_failWithError:(NSError *)error;
{
    dispatch_async(_workQueue, ^{
        if (self.readyState != SR_CLOSED) {
            dispatch_async(_callbackQueue, ^{
                _onError(self, error);
            });

            self.readyState = SR_CLOSED;

            SRFastLog(@"Failing with error %@", error.localizedDescription);
            
            [self _disconnect];
        }
    });
}

- (void)_writeData:(NSData *)data;
{    
    assert(dispatch_get_current_queue() == _workQueue);

    if (_closeWhenFinishedWriting) {
            return;
    }
    [_outputBuffer appendData:data];
    [self _pumpWriting];
}
- (void)send:(id)data;
{
    // TODO: maybe not copy this for performance
    data = [data copy];
    dispatch_async(_workQueue, ^{
        if ([data isKindOfClass:[NSString class]]) {
            [self _sendFrameWithOpcode:SROpCodeTextFrame data:[(NSString *)data dataUsingEncoding:NSUTF8StringEncoding]];
        } else if ([data isKindOfClass:[NSData class]]) {
            [self _sendFrameWithOpcode:SROpCodeBinaryFrame data:data];
        } else if (data == nil) {
            [self _sendFrameWithOpcode:SROpCodeTextFrame data:data];
        } else {
            assert(NO);
        }
    });
}

- (void)handlePing:(NSData *)pingData;
{
    [self _sendFrameWithOpcode:SROpCodePong data:pingData];
}

- (void)handlePong;
{
    // NOOP
}

- (void)handleMessage:(id)message
{
    dispatch_async(_callbackQueue, ^{
        _onMessage(self, message);
    });
}


static inline BOOL closeCodeIsValid(int closeCode) {
    if (closeCode < 1000) {
        return NO;
    }
    
    if (closeCode >= 1000 && closeCode <= 1011) {
        if (closeCode == 1004 ||
            closeCode == 1005 ||
            closeCode == 1006) {
            return NO;
        }
        return YES;
    }
    
    if (closeCode >= 3000 && closeCode <= 3999) {
        return YES;
    }
    
    if (closeCode >= 4000 && closeCode <= 4999) {
        return YES;
    }

    return NO;
}

//  Note from RFC:
//
//  If there is a body, the first two
//  bytes of the body MUST be a 2-byte unsigned integer (in network byte
//  order) representing a status code with value /code/ defined in
//  Section 7.4.  Following the 2-byte integer the body MAY contain UTF-8
//  encoded data with value /reason/, the interpretation of which is not
//  defined by this specification.

- (void)handleCloseWithData:(NSData *)data;
{
    size_t dataSize = data.length;
    __block uint16_t closeCode = 0;
    
    NSString *reason = nil;
    
    SRFastLog(@"Received close frame");
    
    if (dataSize == 1) {
        // TODO handle error
        [self _closeWithProtocolError:@"Payload for close must be larger than 2 bytes"];
        return;
    } else if (dataSize >= 2) {
        [data getBytes:&closeCode length:sizeof(closeCode)];
        _closeCode = EndianU16_BtoN(closeCode);
        if (!closeCodeIsValid(_closeCode)) {
            [self _closeWithProtocolError:[NSString stringWithFormat:@"Cannot have close code of %d", _closeCode]];
            return;
        }
        if (dataSize > 2) {
            reason = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(2, dataSize - 2)] encoding:NSUTF8StringEncoding];
            if (!reason) {
                [self _closeWithProtocolError:@"Close reason MUST be valid UTF-8"];
                return;
            }
        }
    } else {
        _closeCode = SRStatusNoStatusReceived;
    }
    
    assert(dispatch_get_current_queue() == _workQueue);
    
    dispatch_async(_workQueue, ^{
        if (self.readyState == SR_OPEN) {
            [self closeWithCode:1000 reason:reason];
        }
        [self _disconnect];
    });
}

- (void)_disconnect;
{
    SRFastLog(@"Trying to disconnect");
    dispatch_async(_workQueue, ^{
        _closeWhenFinishedWriting = YES;
        [self _pumpWriting];
    });
}

- (void)_handleFrameWithData:(NSData *)frameData opCode:(NSInteger)opcode;
{                
    // Check that the current data is valid UTF8
    
    BOOL isControlFrame = (opcode == SROpCodePing || opcode == SROpCodePong || opcode == SROpCodeConnectionClose);
    if (!isControlFrame) {
        [self _readFrameNew];
    } else {
        dispatch_async(_workQueue, ^{
            [self _readFrameContinue];
        });
    }
    
    switch (opcode) {
        case SROpCodeTextFrame: {
            NSString *str = [[NSString alloc] initWithData:frameData encoding:NSUTF8StringEncoding];
            if (str == nil && frameData) {
                [self closeWithCode:SRStatusCodeInvalidUTF8 reason:@"Text frames must be valid UTF-8"];
                dispatch_async(_workQueue, ^{
                    [self _disconnect];
                });

                return;
            }
            [self handleMessage:str];
            break;
        }
        case SROpCodeBinaryFrame:
            [self handleMessage:[frameData copy]];
            break;
        case SROpCodeConnectionClose:
            [self handleCloseWithData:frameData];
            break;
        case SROpCodePing:
            [self handlePing:frameData];
            break;
        case SROpCodePong:
            [self handlePong];
            break;
        default:
            [self _closeWithProtocolError:[NSString stringWithFormat:@"Unknown opcode %d", opcode]];
            // TODO: Handle invalid opcode
            break;
    }
}

- (void)_handleFrameHeader:(frame_header)frame_header curData:(NSData *)curData;
{
    assert(frame_header.opcode != 0);
    
    if (self.readyState != SR_OPEN) {
        return;
    }
    
    
    BOOL isControlFrame = (frame_header.opcode == SROpCodePing || frame_header.opcode == SROpCodePong || frame_header.opcode == SROpCodeConnectionClose);
    
    if (isControlFrame && !frame_header.fin) {
        [self _closeWithProtocolError:@"Fragmented control frames not allowed"];
        return;
    }
    
    if (isControlFrame && frame_header.payload_length >= 126) {
        [self _closeWithProtocolError:@"Control frames cannot have payloads larger than 126 bytes"];
        return;
    }
    
    if (!isControlFrame) {
        _currentFrameOpcode = frame_header.opcode;
        _currentFrameCount += 1;
    }
    
    if (frame_header.payload_length == 0) {
        if (isControlFrame) {
            [self _handleFrameWithData:curData opCode:frame_header.opcode];
        } else {
            if (frame_header.fin) {
//                assert(_currentFrameData.length == frame_header.payload_length);
                [self _handleFrameWithData:_currentFrameData opCode:frame_header.opcode];
            } else {
                // TODO add assert that opcode is not a control;
                [self _readFrameContinue];
            }
        }
    } else {
        [self _addConsumerWithDataLength:frame_header.payload_length callback:^(SRWebSocket *self, NSData *newData) {
            if (isControlFrame) {
                [self _handleFrameWithData:newData opCode:frame_header.opcode];
            } else {
                if (frame_header.fin) {
                    [self _handleFrameWithData:_currentFrameData opCode:frame_header.opcode];
                } else {
                    // TODO add assert that opcode is not a control;
                    [self _readFrameContinue];
                }
                
            }
        } readToCurrentFrame:!isControlFrame unmaskBytes:frame_header.masked];
    }
}

/* From RFC:

 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
 +-+-+-+-+-------+-+-------------+-------------------------------+
 |F|R|R|R| opcode|M| Payload len |    Extended payload length    |
 |I|S|S|S|  (4)  |A|     (7)     |             (16/64)           |
 |N|V|V|V|       |S|             |   (if payload len==126/127)   |
 | |1|2|3|       |K|             |                               |
 +-+-+-+-+-------+-+-------------+ - - - - - - - - - - - - - - - +
 |     Extended payload length continued, if payload len == 127  |
 + - - - - - - - - - - - - - - - +-------------------------------+
 |                               |Masking-key, if MASK set to 1  |
 +-------------------------------+-------------------------------+
 | Masking-key (continued)       |          Payload Data         |
 +-------------------------------- - - - - - - - - - - - - - - - +
 :                     Payload Data continued ...                :
 + - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - +
 |                     Payload Data continued ...                |
 +---------------------------------------------------------------+
 */

static const uint8_t SRFinMask          = 0x80;
static const uint8_t SROpCodeMask       = 0x0F;
static const uint8_t SRRsvMask          = 0x70;
static const uint8_t SRMaskMask         = 0x80;
static const uint8_t SRPayloadLenMask   = 0x7F;


- (void)_readFrameContinue;
{
    assert((_currentFrameCount == 0 && _currentFrameOpcode == 0) || (_currentFrameCount > 0 && _currentFrameOpcode > 0));

    [self _addConsumerWithDataLength:2 callback:^(SRWebSocket *self, NSData *data) {
        __block frame_header header = {0};
        
        
        const uint8_t *headerBuffer = data.bytes;
        assert(data.length >= 2);
        
        if (headerBuffer[0] & SRRsvMask) {
            [(__unsafe_unretained SRWebSocket *)self _closeWithProtocolError:@"Server used RSV bits"];
            return;
        }
        
        uint8_t receivedOpcode = (SROpCodeMask & headerBuffer[0]);
        
        BOOL isControlFrame = (receivedOpcode == SROpCodePing || receivedOpcode == SROpCodePong || receivedOpcode == SROpCodeConnectionClose);
        
        if (!isControlFrame && receivedOpcode != 0 && self->_currentFrameCount > 0) {
            [self _closeWithProtocolError:@"all data frames after the initial data frame must have opcode 0"];
            return;
        }
        
        if (receivedOpcode == 0 && _currentFrameCount == 0) {
            [self _closeWithProtocolError:@"cannot continue a message"];
            return;
        }
        
        header.opcode = receivedOpcode == 0 ? _currentFrameOpcode : receivedOpcode;
        
        header.fin = !!(SRFinMask & headerBuffer[0]);
        
        
        header.masked = !!(SRMaskMask & headerBuffer[1]);
        header.payload_length = SRPayloadLenMask & headerBuffer[1];
        
        headerBuffer = NULL;
        
        if (header.masked) {
            [self _closeWithProtocolError:@"Client must receive unmasked data"];
        }
        
        size_t extra_bytes_needed = header.masked ? sizeof(_currentReadMaskKey) : 0;
        
        if (header.payload_length == 126) {
            extra_bytes_needed += sizeof(uint16_t);
        } else if (header.payload_length == 127) {
            extra_bytes_needed += sizeof(uint64_t);
        }
        
        if (extra_bytes_needed == 0) {
            [self _handleFrameHeader:header curData:_currentFrameData];
        } else {
            [self _addConsumerWithDataLength:extra_bytes_needed callback:^(SRWebSocket *self, NSData *data) {
                size_t mapped_size = data.length;
                const void *mapped_buffer = data.bytes;
                size_t offset = 0;
                
                if (header.payload_length == 126) {
                    assert(mapped_size >= sizeof(uint16_t));
                    uint16_t newLen = EndianU16_BtoN(*(uint16_t *)(mapped_buffer));
                    header.payload_length = newLen;
                    offset += sizeof(uint16_t);
                } else if (header.payload_length == 127) {
                    assert(mapped_size >= sizeof(uint64_t));
                    header.payload_length = EndianU64_BtoN(*(uint64_t *)(mapped_buffer));
                    offset += sizeof(uint64_t);
                } else {
                    assert(header.payload_length < 126 && header.payload_length >= 0);
                }
                
                
                if (header.masked) {
                    assert(mapped_size >= sizeof(_currentReadMaskOffset) + offset);
                    memcpy(_currentReadMaskKey, ((uint8_t *)mapped_buffer) + offset, sizeof(_currentReadMaskKey));
                }
                
                [self _handleFrameHeader:header curData:_currentFrameData];
            } readToCurrentFrame:NO unmaskBytes:NO];
        }
    } readToCurrentFrame:NO unmaskBytes:NO];
}

- (void)_readFrameNew;
{
    dispatch_async(_workQueue, ^{
        [_currentFrameData setLength:0];
        
        _currentFrameOpcode = 0;
        _currentFrameCount = 0;
        _readOpCount = 0;
        _currentStringScanPosition = 0;
        
        [self _readFrameContinue];
    });
}

- (void)_pumpWriting;
{
    assert(dispatch_get_current_queue() == _workQueue);
    
    NSUInteger dataLength = _outputBuffer.length;
    if (dataLength - _outputBufferOffset > 0 && _outputStream.hasSpaceAvailable) {
        NSUInteger bytesWritten = [_outputStream write:_outputBuffer.bytes + _outputBufferOffset maxLength:dataLength - _outputBufferOffset];
        if (bytesWritten == -1) {
            [self _failWithError:[NSError errorWithDomain:@"org.lolrus.SocketRocket" code:2145 userInfo:[NSDictionary dictionaryWithObject:@"Error writing to stream" forKey:NSLocalizedDescriptionKey]]];
             return;
        }
        
        _outputBufferOffset += bytesWritten;
        
        if (_outputBufferOffset > 4096 && _outputBufferOffset > (_outputBuffer.length >> 1)) {
            _outputBuffer = [[NSMutableData alloc] initWithBytes:(char *)_outputBuffer.bytes + _outputBufferOffset length:_outputBuffer.length - _outputBufferOffset];
            _outputBufferOffset = 0;
        }

    }
    
    if (_closeWhenFinishedWriting && _outputBuffer.length - _outputBufferOffset == 0 && (_inputStream.streamStatus != NSStreamStatusNotOpen && _inputStream.streamStatus != NSStreamStatusClosed)) {
        [_outputStream close];
        [_inputStream close];
        
        dispatch_async(_callbackQueue, ^{
            _onClose(self, _closeCode, nil, YES);
        });
    }
}

- (void)_addConsumerWithScanner:(stream_scanner)consumer callback:(data_callback)callback;
{
    [self _addConsumerWithScanner:consumer callback:callback dataLength:0];
}

- (void)_addConsumerWithDataLength:(size_t)dataLength callback:(data_callback)callback readToCurrentFrame:(BOOL)readToCurrentFrame unmaskBytes:(BOOL)unmaskBytes;
{   
    assert(dataLength);
    
    dispatch_async(_workQueue, ^{
        [_consumers addObject:[[SRIOConsumer alloc] initWithScanner:nil handler:callback bytesNeeded:dataLength readToCurrentFrame:readToCurrentFrame unmaskBytes:unmaskBytes]];
        [self _pumpScanner];
    });
}

- (void)_addConsumerWithScanner:(stream_scanner)consumer callback:(data_callback)callback dataLength:(size_t)dataLength;
{    
    dispatch_async(_workQueue, ^{
        [_consumers addObject:[[SRIOConsumer alloc] initWithScanner:consumer handler:callback bytesNeeded:dataLength readToCurrentFrame:NO unmaskBytes:NO]];
        [self _pumpScanner];
    });
}

     
static const char CRLFCRLFBytes[] = {'\r', '\n', '\r', '\n'};

- (void)_readUntilHeaderCompleteWithCallback:(data_callback)dataHandler;
{
    [self _readUntilBytes:CRLFCRLFBytes length:sizeof(CRLFCRLFBytes) callback:dataHandler];
}

- (void)_readUntilBytes:(const void *)bytes length:(size_t)length callback:(data_callback)dataHandler;
{
    // TODO optimize so this can continue from where we last searched
    stream_scanner consumer = ^size_t(NSData *data) {
        __block size_t found_size = 0;
        __block size_t match_count = 0;
        
        size_t size = data.length;
        const unsigned char *buffer = data.bytes;
        for (int i = 0; i < size; i++ ) {
            if (((const unsigned char *)buffer)[i] == ((const unsigned char *)bytes)[match_count]) {
                match_count += 1;
                if (match_count == length) {
                    found_size = i + 1;
                    break;
                }
            } else {
                match_count = 0;
            }
        }
        return found_size;
    };
    [self _addConsumerWithScanner:consumer callback:dataHandler];
}

-(void)_pumpScanner;
{
    assert(dispatch_get_current_queue() == _workQueue);

    if (self.readyState >= SR_CLOSING) {
        return;
    }
    
    if (!_consumers.count) {
        return;
    }
    
    size_t curSize = _readBuffer.length - _readBufferOffset;
    if (!curSize) {
        return;
    }

    SRIOConsumer *consumer = [_consumers objectAtIndex:0];
    
    size_t bytesNeeded = consumer.bytesNeeded;
   
    size_t foundSize = 0;
    if (consumer.consumer) {
        NSData *tempView = [NSData dataWithBytesNoCopy:(char *)_readBuffer.bytes + _readBufferOffset length:_readBuffer.length - _readBufferOffset freeWhenDone:NO];  
        foundSize = consumer.consumer(tempView);
    } else {
        assert(consumer.bytesNeeded);
        if (curSize >= bytesNeeded) {
            foundSize = bytesNeeded;
        } else if (consumer.readToCurrentFrame) {
            foundSize = curSize;
        }
    }

    NSData *slice = nil;
    if (consumer.readToCurrentFrame || foundSize) {
        NSRange sliceRange = NSMakeRange(_readBufferOffset, foundSize);
        slice = [_readBuffer subdataWithRange:sliceRange];
        
        _readBufferOffset += foundSize;

        if (_readBufferOffset > 4096 && _readBufferOffset > (_readBuffer.length >> 1)) {
            _readBuffer = [[NSMutableData alloc] initWithBytes:(char *)_readBuffer.bytes + _readBufferOffset length:_readBuffer.length - _readBufferOffset];            _readBufferOffset = 0;
        }
        
        if (consumer.unmaskBytes) {
            NSMutableData *mutableSlice = [slice mutableCopy];
           
            NSUInteger len = mutableSlice.length;
            uint8_t *bytes = mutableSlice.mutableBytes;

            for (int i = 0; i < len; i++) {
                bytes[i] = bytes[i] ^ _currentReadMaskKey[_currentReadMaskOffset % sizeof(_currentReadMaskKey)];
                _currentReadMaskOffset += 1;
            }
            
            slice = mutableSlice;
        }

        if (consumer.readToCurrentFrame) {
            [_currentFrameData appendData:slice];
            
            _readOpCount += 1;

            if (_currentFrameOpcode == SROpCodeTextFrame) {
                // Validate UTF8 stuff.
                size_t currentDataSize = _currentFrameData.length;
                if (_currentFrameOpcode == SROpCodeTextFrame && currentDataSize > 0) {
                    // TODO: Optimize the crap out of this.  Don't really have to copy all the data each time
                    
                    size_t scanSize = currentDataSize - _currentStringScanPosition;
                    
                    NSData *scan_data = [_currentFrameData subdataWithRange:NSMakeRange(_currentStringScanPosition, scanSize)];
                    int32_t valid_utf8_size = validate_dispatch_data_partial_string(scan_data);
                    
                    if (valid_utf8_size == -1) {
                        [self closeWithCode:SRStatusCodeInvalidUTF8 reason:@"Text frames must be valid UTF-8"];
                        dispatch_async(_workQueue, ^{
                            [self _disconnect];
                        });
                        return;
                    } else {
                        _currentStringScanPosition += valid_utf8_size;
                    }
                } 

            }
            
            consumer.bytesNeeded -= foundSize;
            
            if (consumer.bytesNeeded == 0) {
                consumer.handler(self, nil);
                [_consumers removeObjectAtIndex:0];
            }
        } else if (foundSize) {
            consumer.handler(self, slice);
            [_consumers removeObjectAtIndex:0];
        }
        
        dispatch_async(_workQueue, ^{
            [self _pumpScanner];
        });
    }
}

//#define NOMASK

static const size_t SRFrameHeaderOverhead = 32;

- (void)_sendFrameWithOpcode:(SROpCode)opcode data:(id)data;
{
    assert(dispatch_get_current_queue() == _workQueue);
    
    NSAssert(data == nil || [data isKindOfClass:[NSData class]] || [data isKindOfClass:[NSString class]], @"Function expects nil, NSString or NSData");
    
    size_t payloadLength = [data isKindOfClass:[NSString class]] ? [(NSString *)data lengthOfBytesUsingEncoding:NSUTF8StringEncoding] : [data length];
        
    NSMutableData *frame = [[NSMutableData alloc] initWithLength:payloadLength + SRFrameHeaderOverhead];
    if (!frame) {
        [self closeWithCode:SRStatusCodeMessageTooBig reason:@"Message too big"];
        return;
    }
    uint8_t *frame_buffer = (uint8_t *)[frame mutableBytes];
    
    // set fin
    frame_buffer[0] = SRFinMask | opcode;
    
    BOOL useMask = YES;
#ifdef NOMASK
    useMask = NO;
#endif
    
    if (useMask) {
    // set the mask and header
        frame_buffer[1] |= SRMaskMask;
    }
    
    size_t frame_buffer_size = 2;
    
    const uint8_t *unmasked_payload = NULL;
    if ([data isKindOfClass:[NSData class]]) {
        unmasked_payload = (uint8_t *)[data bytes];
    } else if ([data isKindOfClass:[NSString class]]) {
        unmasked_payload =  (const uint8_t *)[data UTF8String];
    }
    
    if (payloadLength < 126) {
        frame_buffer[1] |= payloadLength;
    } else if (payloadLength <= UINT16_MAX) {
        frame_buffer[1] |= 126;
        *((uint16_t *)(frame_buffer + frame_buffer_size)) = EndianU16_BtoN((uint16_t)payloadLength);
        frame_buffer_size += sizeof(uint16_t);
    } else {
        frame_buffer[1] |= 127;
        *((uint64_t *)(frame_buffer + frame_buffer_size)) = EndianU64_BtoN((uint64_t)payloadLength);
        frame_buffer_size += sizeof(uint64_t);
    }
        
    if (!useMask) {
        for (int i = 0; i < payloadLength; i++) {
            frame_buffer[frame_buffer_size] = unmasked_payload[i];
            frame_buffer_size += 1;
        }
    } else {
        uint8_t *mask_key = frame_buffer + frame_buffer_size;
        SecRandomCopyBytes(kSecRandomDefault, sizeof(uint32_t), (uint8_t *)mask_key);
        frame_buffer_size += sizeof(uint32_t);
        
        // TODO: could probably optimize this with SIMD
        for (int i = 0; i < payloadLength; i++) {
            frame_buffer[frame_buffer_size] = unmasked_payload[i] ^ mask_key[i % sizeof(uint32_t)];
            frame_buffer_size += 1;
        }
    }

    assert(frame_buffer_size <= [frame length]);
    frame.length = frame_buffer_size;
    
    [self _writeData:frame];
}

- (void)stream:(NSStream *)aStream handleEvent:(NSStreamEvent)eventCode;
{
//    SRFastLog(@"%@ Got stream event %d", aStream, eventCode);
    switch (eventCode) {
        case NSStreamEventOpenCompleted: {
            SRFastLog(@"NSStreamEventOpenCompleted %@", aStream);
            if (self.readyState >= SR_CLOSING) {
                return;
            }
            
            assert(_readBuffer);

            dispatch_async(_workQueue, ^{
                if (self.readyState == SR_CONNECTING && aStream == _inputStream) {
                    [self didConnect];
                }
                [self _pumpWriting];
                [self _pumpScanner];
            });
            break;
        }
            
        case NSStreamEventErrorOccurred: {
            SRFastLog(@"NSStreamEventErrorOccurred %@ %@", aStream, [aStream streamError]);
            /// TODO specify error better!
            [self _failWithError:aStream.streamError];
            _readBufferOffset = 0;
            [_readBuffer setLength:0];
            break;
            
        }
            
        case NSStreamEventEndEncountered: {
            SRFastLog(@"NSStreamEventEndEncountered %@", aStream);
            if (aStream.streamError) {
                [self _failWithError:aStream.streamError];
            }
            
            if (self.readyState != SR_CLOSED) {
                self.readyState = SR_CLOSED;
            }
            break;
        }
            
        case NSStreamEventHasBytesAvailable: {
            dispatch_async(_workQueue, ^{
                const int bufferSize = 2048;
                uint8_t buffer[bufferSize];
                
                while (_inputStream.hasBytesAvailable) {
                    int bytes_read = [_inputStream read:buffer maxLength:bufferSize];
                
                    if (bytes_read > 0) {
                        [_readBuffer appendBytes:buffer length:bytes_read];
                    } else if (bytes_read < 0) {
                        [self _failWithError:_inputStream.streamError];
                    }
                    
                    if (bytes_read != bufferSize) {
                        break;
                    }
                };
                [self _pumpScanner];
            });
            break;
        }
            
        case NSStreamEventHasSpaceAvailable: {
            dispatch_async(_workQueue, ^{
                [self _pumpWriting];
            });
            break;
        }
            
        default:
            break;
    }
}

@end


@implementation SRIOConsumer

@synthesize bytesNeeded = _bytesNeeded;
@synthesize consumer = _scanner;
@synthesize handler = _handler;
@synthesize readToCurrentFrame = _readToCurrentFrame;
@synthesize unmaskBytes = _unmaskBytes;

- (id)initWithScanner:(stream_scanner)scanner handler:(data_callback)handler bytesNeeded:(size_t)bytesNeeded readToCurrentFrame:(BOOL)readToCurrentFrame unmaskBytes:(BOOL)unmaskBytes;
{
    self = [super init];
    if (self) {
        _scanner = [scanner copy];
        _handler = [handler copy];
        _bytesNeeded = bytesNeeded;
        _readToCurrentFrame = readToCurrentFrame;
        _unmaskBytes = unmaskBytes;
        assert(_scanner || _bytesNeeded);
    }
    return self;
}

@end



