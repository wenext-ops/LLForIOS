//
//  WCWebSocketManage.m
//  TenextCloud
//
//  Created by 侯兴宇 on 2019/9/27.
//  Copyright © 2019 Winext. All rights reserved.
//

#import "QCSocketManager.h"
#import "QCWebSocket.h"
#import "NSString+Extension.h"
#import "WCAppEnvironment.h"

#import "QCMacros.h"

#define dispatch_main_async_safe(block)\
if ([NSThread isMainThread]) {\
block();\
} else {\
dispatch_async(dispatch_get_main_queue(), block);\
}

#define WeakSelf(type)  __weak typeof(type) weak##type = type;



static NSString *heartBeatReqID = @"5002";

@interface QCSocketManager ()<QCWebSocketDelegate>

@property (nonatomic, strong) QCWebSocket *socket;
@property (nonatomic, strong) NSTimer *heartBeat;
@property (nonatomic, assign) NSTimeInterval reConnectTime;


@end

@implementation QCSocketManager

+(instancetype)shared{
    static QCSocketManager *_instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _instance = [[self alloc]init];
    });
    return _instance;
}

- (instancetype)init{
    self = [super init];
    if (self) {
        
    }
    return self;
}

-(void)dealloc{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}



-(void)socketOpen{
    
    if(self.socket.readyState == QC_OPEN){
        return;
    }
    
    [self.socket open];
}

-(void)socketClose{
    if (self.socket){
        [self.socket close];
        self.socket = nil;
        //断开连接时销毁心跳
        [self destoryHeartBeat];
    }
}




#pragma mark - socket delegate

- (void)webSocketDidOpen:(QCWebSocket *)webSocket {
    
    //每次正常连接的时候清零重连时间
    self.reConnectTime = 0;
    
    //开启心跳
    [self performSelector:@selector(initHeartBeat) withObject:nil afterDelay:20];
    
    if (webSocket == self.socket) {
        QCLog(@"************************** socket 连接成功************************** ");
        if ([self.delegate respondsToSelector:@selector(socketDidOpen:)]) {
            [self.delegate socketDidOpen:self];
        }
    }
}

- (void)webSocket:(QCWebSocket *)webSocket didFailWithError:(NSError *)error {

    if (webSocket == self.socket) {
        QCLog(@"************************** socket 连接失败************************** ");
        //连接失败就重连
        [self reConnect];
        
        if ([self.delegate respondsToSelector:@selector(socket:didFailWithError:)]) {
            [self.delegate socket:self didFailWithError:error];
        }
    }
}

- (void)webSocket:(QCWebSocket *)webSocket didCloseWithCode:(NSInteger)code reason:(NSString *)reason wasClean:(BOOL)wasClean {
    
    if (webSocket == self.socket) {
        QCLog(@"************************** socket连接断开************************** ");
        QCLog(@"被关闭连接，code:%ld,reason:%@,wasClean:%d",(long)code,reason,wasClean);
        [self socketClose];
        if ([self.delegate respondsToSelector:@selector(socket:didCloseWithCode:reason:wasClean:)]) {
            [self.delegate socket:self didCloseWithCode:code reason:reason wasClean:wasClean];
        }
    }

}

-(void)webSocket:(QCWebSocket *)webSocket didReceivePong:(NSData *)pongPayload{
//    NSString *reply = [[NSString alloc] initWithData:pongPayload encoding:NSUTF8StringEncoding];
//    QCLog(@"reply===%@",reply);
}

#pragma mark - 收到的回调
- (void)webSocket:(QCWebSocket *)webSocket didReceiveMessage:(id)message  {
    
    if (webSocket == self.socket) {
        if(!message){
            return;
        }
        [self handleReceivedMessage:message];

    }
}


- (void)handleReceivedMessage:(id)message{
    NSDictionary *dic = [NSString jsonToObject:message];
    QCLog(@"message:%@",dic);
    NSString *reqId = [NSString stringWithFormat:@"%@",dic[@"reqId"]];
    if ([heartBeatReqID isEqualToString:reqId]) {//心跳回包
        return;
    }
    
    if ([self.delegate respondsToSelector:@selector(socket:didReceiveMessage:)]) {
        [self.delegate socket:self didReceiveMessage:message];
    }
}

#pragma mark - private

//重连
- (void)reConnect
{
    [self socketClose];
    //超过一分钟就不再重连 所以只会重连5次
    if (self.reConnectTime > 16) {
        //您的网络状况不是很好，请检查网络后重试
        return;
    }
   
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.reConnectTime * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self socketOpen];
        QCLog(@"重连");
    });
    
    //重连时间2的指数级增长
    if (self.reConnectTime == 0) {
        self.reConnectTime = 2;
    }else{
        self.reConnectTime *= 2;
    }
    
}

//初始化心跳
- (void)initHeartBeat
{
    dispatch_main_async_safe(^{
        [self destoryHeartBeat];
       
        self.heartBeat = [NSTimer timerWithTimeInterval:30 target:self selector:@selector(ping) userInfo:nil repeats:YES];
        //和服务端约定好发送什么作为心跳标识，尽可能的减小心跳包大小
        [[NSRunLoop currentRunLoop] addTimer:self.heartBeat forMode:NSRunLoopCommonModes];
    })
}


//取消心跳
- (void)destoryHeartBeat
{
    dispatch_main_async_safe(^{
        if (self.heartBeat) {
            if ([self.heartBeat respondsToSelector:@selector(isValid)]){
                if ([self.heartBeat isValid]){
                    [self.heartBeat invalidate];
                    self.heartBeat = nil;
                }
            }
        }
    })
}

//pingPong
- (void)ping{
    if (self.socket.readyState == QC_OPEN) {
        NSData *data= [NSJSONSerialization dataWithJSONObject:[self heartData] options:NSJSONWritingPrettyPrinted error:nil];
        [self.socket send:data];
    }
}

//pingPong 数据 （心跳数据）
- (NSDictionary *)heartData{
    return @{@"action":@"Hello",@"reqId":heartBeatReqID};
}


- (void)sendData:(NSDictionary *)obj {
    
    NSError *error;
    NSString *data;
    
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:obj
                                                       options:0
                                                         error:&error];
    if (!jsonData) {
        QCLog(@" error: %@", error.localizedDescription);
        return;
    } else {
        data = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        //这是为了取代requestURI里的"\"
        //data = [data stringByReplacingOccurrencesOfString:@"\\" withString:@""];
    }
    WeakSelf(self);
    dispatch_queue_t queue =  dispatch_queue_create("zy", NULL);
    
    dispatch_async(queue, ^{
        if (weakself.socket != nil) {
            // 只有 QC_OPEN 开启状态才能调 send 方法啊，不然要崩
            if (weakself.socket.readyState == QC_OPEN) {
                [weakself.socket send:data];    // 发送数据
                
            } else if (weakself.socket.readyState == QC_CONNECTING) {

                [weakself reConnect];
                
            } else if (weakself.socket.readyState == QC_CLOSING || weakself.socket.readyState == QC_CLOSED) {
                // websocket 断开了，调用 reConnect 方法重连
                QCLog(@"重连");
                
                [weakself reConnect];
            }
        } else {
            
            [weakself socketOpen];
        }
    });
}



#pragma mark - getter


- (QCWebSocket *)socket
{
    if (!_socket) {
        _socket = [[QCWebSocket alloc] initWithURLRequest:
        [NSURLRequest requestWithURL:[NSURL URLWithString:[WCAppEnvironment shareEnvironment].wsUrl]]];
        _socket.delegate = self;
    }
    return _socket;
}

- (WCReadyState)socketReadyState{
    switch (self.socket.readyState) {
        case QC_OPEN:
            return WC_OPEN;
            break;
        case QC_CONNECTING:
            return WC_CONNECTING;
            break;
        case QC_CLOSING:
            return WC_CLOSING;
            break;
        case QC_CLOSED:
            return WC_CLOSED;
            break;
        default:
            break;
    }
}
@end
