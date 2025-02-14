//
//  ErizoClientIOS
//
//  Copyright (c) 2015 Alvaro Gil (zevarito@gmail.com).
//
//  MIT License, see LICENSE file for details.
//

#import <Foundation/Foundation.h>

#import "ECSignalingMessage.h"
#import "ECSignalingChannel.h"
#import "ECSignalingEvent.h"
#import "RTCSessionDescription+JSON.h"
#import "Logger.h"
@import SocketIO;

#define ASSERT_STREAM_ID_STRING(streamId) { \
NSAssert([streamId isKindOfClass:[NSString class]], @"streamId needs to be a string");\
}

#define BY_PASS_SELF_SIGN

typedef void(^SocketIOCallback)(NSArray* data);

@interface ECSignalingChannel ()
@end

@implementation ECSignalingChannel {
    SocketIOClient *socketIO;
    BOOL isConnected;
    NSString *encodedToken;
    NSDictionary *decodedToken;
    NSMutableDictionary *outMessagesQueues;
    NSMutableDictionary *streamSignalingDelegates;
    NSDictionary *roomMetadata;
    SocketManager *manager;
    int socketgd;
}

- (instancetype)initWithEncodedToken:(NSString *)token
                        roomDelegate:(id<ECSignalingChannelRoomDelegate>)roomDelegate
                      clientDelegate:(id<ECClientDelegate>)clientDelegate {
    if (self = [super init]) {
        _roomDelegate = roomDelegate;
        encodedToken = token;
        [self decodeToken:token];
    }
    return self;
}

- (void)connect {
    L_INFO(@"Opening Websocket Connection...");
    outMessagesQueues = [NSMutableDictionary dictionary];
    streamSignalingDelegates = [[NSMutableDictionary alloc] init];
    BOOL secure = [(NSNumber *)[decodedToken objectForKey:@"secure"] boolValue];
    NSString *tokenId = (NSString *)[decodedToken objectForKey:@"tokenId"];
    NSString *signature = (NSString *)[decodedToken objectForKey:@"signature"];
    NSString *host = (NSString *)[decodedToken objectForKey:@"host"];
    //    NSString *urlString = [NSString stringWithFormat:@"https://%@/token",
    NSString *urlString = [NSString stringWithFormat:@"https://%@/socket.io/?singlePC=true&tokeId=%@&host=%@&secure=true&signature=%@&EIO=3&transport=websocket",
                           [decodedToken objectForKey:@"host"],tokenId,host,signature];

//wss://t.callt.net:8030/socket.io/?singlePC=true&tokenId=60cb09c741116a1dc8789c42&host=t.callt.net:8030&secure=true&signature=MGI1ZjAwYTYwNTkyYjdmNTg3NGQ3NWY3NWQ5MjFhMTJhOTkyYTc3MQ==&EIO=3&transport=websocket
    NSURL *url = [NSURL URLWithString:urlString];
    L_INFO(@"Opening Websocket Connection... %@",urlString);

     manager = [[SocketManager alloc] initWithSocketURL:url config:@{
                                                        #ifdef DEBUG
                                                           @"log":@YES,
                                                        #else
                                                            @"log":@NO,
                                                        #endif
                                                           @"singlePC":@YES,
                                                           @"forcePolling": @NO,
                                                           @"forceWebsockets": @YES,
                                                           @"secure": [NSNumber numberWithBool:secure],
                                                           @"reconnects": @NO,
                                                           @"connectParams": decodedToken,
                                                        #ifdef BY_PASS_SELF_SIGN
                                                           @"selfSigned":@YES
                                                        #endif
                                                         }];
    socketIO = manager.defaultSocket;
    
    [socketIO on:@"connect" callback:^(NSArray* data, SocketAckEmitter* ack) {
        L_INFO(@"Websocket Connection success!");
        // https://github.com/lynckia/licode/blob/f2e0ccf31d09418c40929b09a3399d1cf7e9a502/erizo_controller/erizoController/models/Channel.js#L64
        NSMutableDictionary *tokenOptions = [NSMutableDictionary dictionaryWithDictionary:
                                             @{@"singlePC": @YES,
                                               @"token": decodedToken}];
        NSArray *dataToSend = [[NSArray alloc] initWithObjects: tokenOptions, nil];
        [[socketIO emitWithAck:@"token" with:dataToSend] timingOutAfter:0 callback:^(NSArray* data) {
            [self onSendTokenCallback](data);
        }];
    }];
    [socketIO on:@"disconnect" callback:^(NSArray * _Nonnull data, SocketAckEmitter * _Nonnull emitter) {
        L_WARNING(@"Websocket disconnected: %@", data);
        outMessagesQueues = [NSMutableDictionary dictionary];
        streamSignalingDelegates = [[NSMutableDictionary alloc] init];
        [_roomDelegate signalingChannel:self didDisconnectOfRoom:roomMetadata];
        [socketIO removeAllHandlers];
        socketIO = nil;
    }];
    [socketIO on:@"error" callback:^(NSArray * _Nonnull data, SocketAckEmitter * _Nonnull emitter) {
        L_ERROR(@"Websocket error: %@", data);
        NSString *dataString = [NSString stringWithFormat:@"%@", data];
        [_roomDelegate signalingChannel:self didError:dataString];
    }];
    [socketIO on:@"reconnect" callback:^(NSArray * _Nonnull data, SocketAckEmitter * _Nonnull emitter) {
        // TODO
    }];
    [socketIO on:@"reconnectAttempt" callback:^(NSArray * _Nonnull data, SocketAckEmitter * _Nonnull emitter) {
        // TODO
    }];
    [socketIO on:@"statusChange" callback:^(NSArray * _Nonnull data, SocketAckEmitter * _Nonnull emitter) {
        NSLog(@"[WSS]: status change: %@", data);
    }];

    [socketIO on:@"connected" callback:^(NSArray * _Nonnull data, SocketAckEmitter * _Nonnull emitter) {
        NSLog(@"[WSS]: connected: %@", data);
        [self onSendTokenCallback](data);
    }];

    [socketIO on:kEventPublishMe callback:^(NSArray * _Nonnull data, SocketAckEmitter * _Nonnull emitter) {
        [self onSocketPublishMe:[data objectAtIndex:0]];
    }];
    [socketIO on:kEventOnAddStream callback:^(NSArray * _Nonnull data, SocketAckEmitter * _Nonnull emitter) {
        [self onSocketAddStream:[data objectAtIndex:0]];
    }];
    [socketIO on:kEventOnRemoveStream callback:^(NSArray * _Nonnull data, SocketAckEmitter * _Nonnull emitter) {
        [self onSocketRemoveStream:[data objectAtIndex:0]];
    }];
    [socketIO on:kEventSignalingMessageErizo callback:^(NSArray * _Nonnull data, SocketAckEmitter * _Nonnull emitter) {
        [self onSocketSignalingMessage:[data objectAtIndex:0] type:kEventSignalingMessageErizo];
    }];
    [socketIO on:kEventSignalingMessagePeer callback:^(NSArray * _Nonnull data, SocketAckEmitter * _Nonnull emitter) {
        [self onSocketSignalingMessage:[data objectAtIndex:0] type:kEventSignalingMessagePeer];
    }];
    [socketIO on:kEventOnDataStream callback:^(NSArray * _Nonnull data, SocketAckEmitter * _Nonnull emitter) {
        [self onSocketDataStream:[data objectAtIndex:0]];
    }];
    [socketIO on:kEventOnUpdateAttributeStream callback:^(NSArray * _Nonnull data, SocketAckEmitter * _Nonnull emitter) {
        [self onUpdateAttributeStream:[data objectAtIndex:0]];
    }];

    [socketIO connect];
}

- (void)disconnect {
    [socketIO disconnect];
}

- (void)enqueueSignalingMessage:(ECSignalingMessage *)message {
	NSString *key =  [self keyForDelegateWithStreamId:message.streamId peerSocketId:message.peerSocketId connectionId:message.connectionId];

    if (message.type == kECSignalingMessageTypeAnswer ||
        message.type == kECSignalingMessageTypeOffer) {
        [[outMessagesQueues objectForKey:key] insertObject:message atIndex:0];
    } else if (message.type == kECSignalingMessageTypeCandidate) {
        [self sendSignalingMessage:message];
    } else {
        [[outMessagesQueues objectForKey:key] addObject:message];
    }
}

- (void)sendSignalingMessage:(ECSignalingMessage *)message {
    if (message.erizoId == (id)[NSNull null] ||
        message.connectionId == (id)[NSNull null] ||
        !message.connectionId ||
        [message.connectionId isEqualToString:@""]||
        !message.erizoId ||
        [message.erizoId isEqualToString:@""]) {
        L_WARNING(@"Sending orphan signaling message, lack erizoId or connectionId");
		return;
    }
    
    NSError *error;
    NSDictionary *messageDictionary = [NSJSONSerialization
                                       JSONObjectWithData:[message JSONData]
                                       options:NSJSONReadingMutableContainers error:&error];
    
    NSMutableDictionary *data = [NSMutableDictionary dictionary];
	
	if (message.erizoId){
    	[data setObject:message.erizoId forKey:kEventKeyErizoId];
	}
	if (message.connectionId){
		[data setObject:message.connectionId forKey:kEventKeyConnectionId];
	}
    if (message.peerSocketId) {
        [data setObject:message.peerSocketId forKey:kEventKeyPeerSocketId];
    }

    if ([data[@"erizoId"] length] == 0) {
        NSLog(@"cannot be null");
    }

//    if (message.streamId) {
//        [data setObject:message.streamId forKey:kEventKeyStreamId];
//    } else {
//        NSLog(@"no stream id");
//    }
    [data setObject:@"mozilla" forKey:@"browser"];
    [data setObject:messageDictionary forKey:@"msg"];

    [self send: @{@"options": data} name: @"connectionMessage"];
}

- (void)drainMessageQueueForStreamId:(NSString *)streamId peerSocketId:(NSString *)peerSocketId connectionId:(NSString *)connectionId {
    ASSERT_STREAM_ID_STRING(streamId);
	NSString *key =  [self keyForDelegateWithStreamId:streamId peerSocketId:peerSocketId connectionId:connectionId];

    for (ECSignalingMessage *message in [outMessagesQueues objectForKey:key]) {
        [self sendSignalingMessage:message];
    }
    [[outMessagesQueues objectForKey:key] removeAllObjects];
}

- (void)publish:(NSDictionary*)options signalingChannelDelegate:(id<ECSignalingChannelDelegate>)delegate {
    
    NSMutableDictionary *attributes = [options mutableCopy];
    
    if (!options[@"state"]) {
        attributes[@"state"] = @"erizo";
    }

    attributes[@"encryptTransport"] = @YES;
    attributes[@"handlerProfile"] = [NSNull null];
    SocketIOCallback callback = [self onPublishCallback:delegate];
    [[self sendAck: @{@"options": attributes} name: @"publish"] timingOutAfter:10 callback:callback];
}

- (void)unpublish:(NSString *)streamId signalingChannelDelegate:(id<ECSignalingChannelDelegate>)delegate {
    SocketIOCallback callback = [self onUnPublishCallback:streamId];
    [[self sendAck:@{@"options": @{@"id": [self longStreamId:streamId]}} name:@"unpublish"] timingOutAfter:10 callback:callback];
}

- (void)publishToPeerID:(NSString *)peerSocketId signalingChannelDelegate:(id<ECSignalingChannelDelegate>)delegate {
    L_INFO(@"Publishing streamId: %@ to peerSocket: %@", delegate.streamId, delegate.peerSocketId);

    // Keep track of an unique delegate for this stream id.
    [self setSignalingDelegate:delegate];

    // Notify room and signaling delegates
    [delegate signalingChannelDidOpenChannel:self];
    [delegate signalingChannel:self readyToPublishStreamId:delegate.streamId peerSocketId:delegate.peerSocketId];
    [_roomDelegate signalingChannel:self didReceiveStreamIdReadyToPublish:delegate.streamId];
}

- (void)subscribe:(NSString *)streamId streamOptions:(NSDictionary *)streamOptions signalingChannelDelegate:(id<ECSignalingChannelDelegate>)delegate {
    ASSERT_STREAM_ID_STRING(streamId);
    NSMutableDictionary *attributes = [NSMutableDictionary dictionaryWithDictionary:streamOptions];
    [attributes setValuesForKeysWithDictionary:@{
                                                 @"browser": @"mozilla",
                                                 @"maxVideoBW": @"300",
                                                 @"encryptTransport": @"true",
                                                 @"metadata": @{@"type":@"subscriber"},
                                                 @"streamId": [self longStreamId:streamId],
                                                 }];

    SocketIOCallback callback = [self onSubscribeMCUCallback:streamId signalingChannelDelegate:delegate];
    [[self sendAck:@{@"options": attributes} name:@"subscribe"] timingOutAfter:0 callback:callback];
}

- (void)unsubscribe:(NSString *)streamId {
    ASSERT_STREAM_ID_STRING(streamId);

    SocketIOCallback callback = [self onUnSubscribeCallback:streamId];
    [[self sendAck:@{@"options": @{@"id": [self longStreamId:streamId]}} name:@"unsubscribe"] timingOutAfter:0 callback:callback];
}


- (void)startRecording:(NSString *)streamId {
    ASSERT_STREAM_ID_STRING(streamId);
    SocketIOCallback callback = [self onStartRecordingCallback:streamId];
    [[self sendAck:@{@"options": @{@"id": [self longStreamId:streamId]}} name:@"startRecorder"] timingOutAfter:0 callback:callback];
}

- (void)sendDataStream:(ECSignalingMessage *)message {

	if (!message.streamId || [message.streamId isEqualToString:@""]) {
		L_WARNING(@"Sending orphan signaling message, lack streamId");
		return;
	}

	NSError *error;
	NSDictionary *messageDictionary = [NSJSONSerialization JSONObjectWithData:[message JSONData] options:NSJSONReadingMutableContainers error:&error];
	NSMutableDictionary *data = [NSMutableDictionary dictionary];

	[data setObject:@([message.streamId longLongValue]) forKey:@"id"];
	[data setObject:messageDictionary forKey:@"options"];

    [self sendAck:data name:@"sendDataStream"];
}

- (void)updateStreamAttributes:(ECSignalingMessage *)message {
	
	if (!message.streamId || [message.streamId isEqualToString:@""]) {
		L_WARNING(@"Sending orphan signaling message, lack streamId");
		return;
	}
	
	NSError *error;
	NSDictionary *messageDictionary = [NSJSONSerialization
									   JSONObjectWithData:[message JSONData]
									              options:NSJSONReadingMutableContainers error:&error];
	
	NSMutableDictionary *data = [NSMutableDictionary dictionary];
	
	[data setObject:@([message.streamId longLongValue]) forKey:@"id"];
	[data setObject:messageDictionary forKey:@"attrs"];
    [self send: @{@"options": data} name: @"updateStreamAttributes"];
}

#
# pragma mark - ECLicodeProtocol
#

- (void)onSocketPublishMe:(NSDictionary *)msg {
    ECSignalingMessage *message = [ECSignalingMessage messageFromDictionary:msg];
    [_roomDelegate signalingChannel:self
   didRequestPublishP2PStreamWithId:message.streamId peerSocketId:message.peerSocketId];
}

- (void)onSocketAddStream:(NSDictionary *)msg {
    ECSignalingEvent *event = [[ECSignalingEvent alloc] initWithName:kEventOnAddStream message:msg];
    [_roomDelegate signalingChannel:self didStreamAddedWithId:event.streamId event:event];
}

- (void)onSocketRemoveStream:(NSDictionary *)msg {
    NSDictionary *data = [msg objectForKey:@"msg"];
    NSString *sId = [NSString stringWithFormat:@"%@", [data objectForKey:@"id"]];
    [_roomDelegate signalingChannel:self didRemovedStreamId:sId];
    NSAssert(sId != nil, @"stream id cannot be null");
}

- (void)onSocketDataStream:(NSDictionary *)msg {
    NSDictionary *dataStream = [msg objectForKey:@"msg"];
    NSString *sId = [NSString stringWithFormat:@"%@", [msg objectForKey:@"id"]];
    if([_roomDelegate respondsToSelector:@selector(signalingChannel:fromStreamId:receivedDataStream:)]) {
        [_roomDelegate signalingChannel:self fromStreamId:sId receivedDataStream:dataStream];
    }
}

- (void)onUpdateAttributeStream:(NSDictionary *)msg {
    //ECSignalingEvent *event = [[ECSignalingEvent alloc] initWithName:kEventOnAddStream
    //                                                         message:msg];
    NSDictionary *attributes = [msg objectForKey:kEventKeyUpdatedAttributes];
    NSString *sId = [NSString stringWithFormat:@"%@", [msg objectForKey:@"id"]];
    if([_roomDelegate respondsToSelector:@selector(signalingChannel:fromStreamId:updateStreamAttributes:)]) {
        [_roomDelegate signalingChannel:self fromStreamId:sId updateStreamAttributes:attributes];
    }
}

- (void)onSocketSignalingMessage:(NSDictionary *)msg type:(NSString *)type {
    ECSignalingMessage *message = [ECSignalingMessage messageFromDictionary:msg];
	NSString *key = nil;
	if (!message.streamId) {
		key = [self startKeyForDelegateWithConnectionId:message.connectionId];
	} else {
		key = [self keyForDelegateWithStreamId:message.streamId peerSocketId:message.peerSocketId connectionId:message.connectionId];
	}

    id<ECSignalingChannelDelegate> signalingDelegate = nil;
	if (!message.streamId) {
		signalingDelegate = [self signalingDelegateForStartKey:key];
	} else {
		signalingDelegate = [self signalingDelegateForKey:key];
	}
    if (!signalingDelegate) {
        signalingDelegate = [_roomDelegate clientDelegateRequiredForSignalingChannel:self];
        [signalingDelegate setStreamId:message.streamId];
        [signalingDelegate setPeerSocketId:message.peerSocketId];
        [self setSignalingDelegate:signalingDelegate];
    }

    [signalingDelegate signalingChannel:self didReceiveMessage:message];
    
    if ([type isEqualToString:kEventSignalingMessagePeer] &&  message.peerSocketId && message.type == kECSignalingMessageTypeOffer) {
        // FIXME: Looks like in P2P mode subscribe callback isn't called after attempt
        // to subscribe a stream, that's why sometimes signalingDelegate couldn't not yet exits
        [signalingDelegate signalingChannelDidOpenChannel:self];
        [signalingDelegate signalingChannel:self readyToSubscribeStreamId:message.streamId peerSocketId:message.peerSocketId];
    }
}

#
# pragma mark - Callback blocks
#

- (SocketIOCallback)onSubscribeMCUCallback:(NSString *)streamId signalingChannelDelegate:(id<ECSignalingChannelDelegate>)signalingDelegate {
    SocketIOCallback _cb = ^(id argsData) {
        ASSERT_STREAM_ID_STRING(streamId);
        L_INFO(@"SignalingChannel Subscribe callback: %@", argsData);
        if ((bool)[argsData objectAtIndex:0]) {
            // Keep track of an unique delegate for this stream id and peer socket if p2p.
            signalingDelegate.streamId = streamId;
			signalingDelegate.erizoId = [argsData objectAtIndex:1];
			signalingDelegate.connectionId = [argsData objectAtIndex:2];
            [self setSignalingDelegate:signalingDelegate];
            
            // Notify signalingDelegate that can start peer negotiation for streamId.
            [signalingDelegate signalingChannelDidOpenChannel:self];
            [signalingDelegate signalingChannel:self readyToSubscribeStreamId:streamId peerSocketId:nil];
        } else {
            L_ERROR(@"SignalingChannel couldn't subscribe streamId: %@", streamId);
        }
    };
    return _cb;
}

- (SocketIOCallback)onPublishCallback:(id<ECSignalingChannelDelegate>)signalingDelegate {
    SocketIOCallback _cb = ^(id argsData) {
        L_INFO(@"SignalingChannel Publish callback: %@", argsData);

        NSString *ackString = [NSString stringWithFormat:@"%@", [argsData objectAtIndex:0]];
        if ([[NSString stringWithFormat:@"NO ACK"] isEqualToString:ackString]) {
            NSString *errorString = @"No ACK received when publishing stream!";
            L_ERROR(errorString);
            [self.roomDelegate signalingChannel:self didError:errorString];
            return;
        }

        // Get streamId for the stream to publish.
		id object = [argsData objectAtIndex:0];
		id object1 = [argsData objectAtIndex:1];
		id object2 = [argsData objectAtIndex:2];
		if(!object || !object1 || !object2 || object == [NSNull null] || object1 == [NSNull null] || object2 == [NSNull null]) {
			if([signalingDelegate respondsToSelector:@selector(signalingChannelPublishFailed:)]) {
				[signalingDelegate signalingChannelPublishFailed:self];
			}
			if([_roomDelegate respondsToSelector:@selector(signalingChannel:didError:)]) {
				[_roomDelegate signalingChannel:self didError:[NSString stringWithFormat:@"%@", [argsData objectAtIndex:1]]];
			}
			return;
		}
        NSString *streamId = [(NSNumber*)[argsData objectAtIndex:0] stringValue];
		NSString *erizoId = (NSString*)[argsData objectAtIndex:1];
		NSString *connectionId = (NSString*)[argsData objectAtIndex:2];
        
        // Client delegate should know about the stream id.
        signalingDelegate.streamId = streamId;
		signalingDelegate.erizoId = erizoId;
		signalingDelegate.connectionId = connectionId;

        if ([erizoId length] == 0) {
            NSLog(@"erizoId is null");
        }
        
        // Keep track of an unique delegate for this stream id.
        [self setSignalingDelegate:signalingDelegate];
        
        // Notify room and signaling delegates
        [signalingDelegate signalingChannelDidOpenChannel:self];
        [signalingDelegate signalingChannel:self readyToPublishStreamId:streamId peerSocketId:nil];
        [_roomDelegate signalingChannel:self didReceiveStreamIdReadyToPublish:streamId];
    };
    return _cb;
}

- (SocketIOCallback)onUnPublishCallback:(NSString *)streamId {
    SocketIOCallback _cb = ^(id argsData) {
        ASSERT_STREAM_ID_STRING(streamId);
        NSArray *response = argsData;
        L_INFO(@"SignalingChannel Unpublish callback: %@", response);
        if ((BOOL)[response objectAtIndex:0]) {
            [_roomDelegate signalingChannel:self didUnpublishStreamWithId:streamId];
        } else {
            L_ERROR(@"signalingChannel Couldn't unpublish stream id: %@", streamId);
        }
    };
    return _cb;
}

- (SocketIOCallback)onUnSubscribeCallback:(NSString *)streamId {
    SocketIOCallback _cb = ^(id argsData) {
        ASSERT_STREAM_ID_STRING(streamId);
        NSArray *response = argsData;
        L_INFO(@"SignalingChannel Unsubscribe callback: %@", response);
        if ((BOOL)[response objectAtIndex:0]) {
            [_roomDelegate signalingChannel:self didUnsubscribeStreamWithId:streamId];
        } else {
            L_ERROR(@"signalingChannel Couldn't unsubscribe stream id: %@", streamId);
        }
    };
    return _cb;
}

- (SocketIOCallback)onSendTokenCallback2 {
    SocketIOCallback _cb = ^(id argsData) {
        NSArray *response = argsData;
        L_INFO(@"SignalingChannel: onSendTokenCallback: %@", response);
        
        // Get message and status
        NSString *status = (NSString *)[response objectAtIndex:0];
        NSString *message = (NSString *)[response objectAtIndex:1];
        
        // If success store room metadata and notify connection.
        if ([status isEqualToString:@"success"]) {
            roomMetadata = [[response objectAtIndex:1] mutableCopy];
            [roomMetadata setValue:[[roomMetadata objectForKey:@"streams"] mutableCopy] forKey:@"streams"];
            // Convert stream ids to strings just in case they were parsed as longs.
            for (int i=0; i<[[roomMetadata objectForKey:@"streams"] count]; i++) {
                NSDictionary *stream = [[roomMetadata objectForKey:@"streams"][i] mutableCopy];
                NSString *sId = [NSString stringWithFormat:@"%@", [stream objectForKey:@"id"]];
                [stream setValue:sId forKey:@"id"];
                [roomMetadata objectForKey:@"streams"][i] = stream;
            }
            [_roomDelegate signalingChannel:self didConnectToRoom:roomMetadata];
        } else {
            [_roomDelegate signalingChannel:self didError:message];
        }
    };
    return _cb;
}

- (SocketIOCallback)onSendTokenCallback {
    SocketIOCallback _cb = ^(id argsData) {
        NSArray *response = argsData;
        L_INFO(@"SignalingChannel: onSendTokenCallback: %@", response);

        // Get message and status
        NSString *message = (NSString *)[response objectAtIndex:0];

        // If success store room metadata and notify connection.
        if (response.count == 2) {
            roomMetadata = [[response objectAtIndex:0] mutableCopy][@"msg"];
            [roomMetadata setValue:[[roomMetadata objectForKey:@"streams"] mutableCopy] forKey:@"streams"];
            // Convert stream ids to strings just in case they were parsed as longs.
            for (int i = 0; i < [[roomMetadata objectForKey:@"streams"] count]; i++) {
                NSDictionary *stream = [[roomMetadata objectForKey:@"streams"][i] mutableCopy];
                NSString *sId = [NSString stringWithFormat:@"%@", [stream objectForKey:@"id"]];
                [stream setValue:sId forKey:@"id"];
                [roomMetadata objectForKey:@"streams"][i] = stream;
            }
            [_roomDelegate signalingChannel:self didConnectToRoom:roomMetadata];
        } else {
            [_roomDelegate signalingChannel:self didError:message];
        }
    };
    return _cb;
}

- (SocketIOCallback)onStartRecordingCallback:(NSString *)streamId {
    SocketIOCallback _cb = ^(id argsData) {
        ASSERT_STREAM_ID_STRING(streamId);
        NSArray *response = argsData;
        L_INFO(@"SignalingChannel onStartRecordingCallback: %@", response);
        
        NSString  *recordingId;
        NSString  *errorStr;
        NSTimeInterval timestamp;
        NSDate *recordingDate = [NSDate date];
        
        if ([[response objectAtIndex:0] isKindOfClass:[NSNull class]]) {
            errorStr = [response objectAtIndex:1];
        } else if ([[response objectAtIndex:0] isKindOfClass:[NSDictionary class]]) {
            recordingId = [[response objectAtIndex:0] objectForKey:@"id"];
            timestamp = [(NSNumber*)[[response objectAtIndex:0] objectForKey:@"timestamp"] integerValue];
            recordingDate = [NSDate dateWithTimeIntervalSince1970:timestamp/1000];
        } else {
            recordingId = [[response objectAtIndex:0] stringValue];
        }
        
        if (!errorStr) {
            [_roomDelegate signalingChannel:self didStartRecordingStreamId:streamId withRecordingId:recordingId recordingDate:recordingDate];
        } else {
            [_roomDelegate signalingChannel:self didFailStartRecordingStreamId:streamId withErrorMsg:errorStr];
        }
    };
    return _cb;
}

#
# pragma mark - Private
#

- (NSNumber *)longStreamId:(NSString *)streamId {
    NSNumberFormatter *f = [[NSNumberFormatter alloc] init];
    return [f numberFromString:streamId];
}

- (void)decodeToken:(NSString *)token {
    NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:token options:0];
    NSAssert(decodedData != nil, @"decoded data cannot be null");
    NSError *jsonParseError = nil;
    decodedToken = [NSJSONSerialization JSONObjectWithData:decodedData options:0 error:&jsonParseError];
    NSAssert(jsonParseError == nil, @"decoded token parse with error");
}

- (void)removeSignalingDelegateForKey:(NSString *)key {
    [streamSignalingDelegates setValue:nil forKey:key];
}

- (void)setSignalingDelegate:(id<ECSignalingChannelDelegate>)delegate {
    [streamSignalingDelegates setValue:delegate forKey:[self keyFromDelegate:delegate]];
    [outMessagesQueues setValue:[NSMutableArray array] forKey:[self keyFromDelegate:delegate]];
}

- (NSString *)keyFromDelegate:(id<ECSignalingChannelDelegate>)delegate {
	return [self keyForDelegateWithStreamId:delegate.streamId peerSocketId:delegate.peerSocketId connectionId:delegate.connectionId];
}

- (NSString *)startKeyFromDelegate:(id<ECSignalingChannelDelegate>)delegate {
	return [self startKeyForDelegateWithConnectionId:delegate.connectionId];
}

- (NSString *)keyForDelegateWithStreamId:(NSString *)streamId peerSocketId:(NSString *)peerSocketId connectionId:(NSString *)connectionId{
    return [NSString stringWithFormat:@"%@-%@-%@", connectionId, streamId, peerSocketId];
}

- (NSString *)startKeyForDelegateWithConnectionId:(NSString *)connectionId{
	return [NSString stringWithFormat:@"%@-", connectionId];
}

- (id<ECSignalingChannelDelegate>)signalingDelegateForKey:(NSString *)key {
    return [streamSignalingDelegates objectForKey:key];
}

- (id<ECSignalingChannelDelegate>)signalingDelegateForStartKey:(NSString *)startKey {
	for (NSString* key in streamSignalingDelegates) {
		if ([key hasPrefix:startKey]) {
			return [streamSignalingDelegates objectForKey:key];
		}
	}
	return nil;
}

- (void)send: (NSDictionary *)data name: (NSString *)name {
    socketgd += 1;
    NSArray *array = @[@{@"msg": data, @"socketgd": @(socketgd)}];
    [socketIO emit:name with:array];
}

- (OnAckCallback *)sendAck: (NSDictionary *)data name: (NSString *)name {
    socketgd += 1;
    NSArray *array = @[@{@"msg": data, @"socketgd": @(socketgd)}];
    return [socketIO emitWithAck: name with: array];
}

@end
