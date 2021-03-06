//
//  BGNetworkManager.m
//  BGNetwork
//
//  Created by user on 15/8/14.
//  Copyright (c) 2015年 lcg. All rights reserved.
//

#import "BGNetworkManager.h"
#import "BGNetworkUtil.h"

static BGNetworkManager *_manager = nil;
@interface BGNetworkManager ()<BGNetworkConnectorDelegate>
@property (nonatomic, strong) BGNetworkConnector *connector;
@property (nonatomic, strong) BGNetworkCache *cache;
@property (nonatomic, strong) dispatch_queue_t workQueue;
@property (nonatomic, strong) dispatch_queue_t dataHandleQueue;
/**
 *  储存请求的字典
 */
@property (nonatomic, strong) NSMutableDictionary *requestDic;
/**
 *  网络配置
 */
@property (nonatomic, strong) BGNetworkConfiguration *configuration;
@end

@implementation BGNetworkManager
+ (instancetype)sharedManager{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _manager = [[BGNetworkManager alloc] init];
    });
    return _manager;
}

- (instancetype)init{
    if(self = [super init]){
        //缓存
        _cache = [BGNetworkCache sharedCache];
        
        //工作队列
        _workQueue = dispatch_queue_create("com.BGNetworkManager.workQueue", DISPATCH_QUEUE_SERIAL);
        
        //数据处理队列
        _dataHandleQueue = dispatch_queue_create("com.BGNEtworkManager.dataHandle", DISPATCH_QUEUE_CONCURRENT);
        
        dispatch_async(_workQueue, ^{
            _requestDic = [[NSMutableDictionary alloc] init];
        });
    }
    return self;
}

- (void)managerSendRequest:(BGNetworkRequest *)request{
    NSParameterAssert(self.connector);
    dispatch_async(self.workQueue, ^{
        switch (request.cachePolicy) {
            case BGNetworkRquestCacheNone:
                //请求网络
                [self loadNetworkDataWithRequest:request];
                break;
            case BGNetworkRequestCacheDataAndReadCacheOnly:
            case BGNetworkRequestCacheDataAndReadCacheLoadData:
                //读取缓存并且请求数据
                [self readCacheAndRequestData:request];
        }
    });
}

- (void)loadNetworkDataWithRequest:(BGNetworkRequest *)request{
    //保存请求
    self.requestDic[[self requestCompleteUrlWithMethodName:request.methodName]] = request;
    //发送请求
    __weak BGNetworkManager *weakManager = self;
    switch (request.httpMethod) {
        case BGNetworkRequestHTTPGet:{
            [self.connector sendGETRequest:request.methodName parameters:request.parametersDic success:^(NSURLSessionDataTask *task, NSData *responseData) {
                [weakManager loadNetworkSuccess:task request:request responseData:responseData];
            } failed:^(NSURLSessionDataTask *task, NSError *error) {
                [weakManager failWithRequest:request error:error];
            }];
        }
            break;
        case BGNetworkRequestHTTPPost:{
            [self.connector sendPOSTRequest:request.methodName parameters:request.parametersDic success:^(NSURLSessionDataTask *task, NSData *responseData) {
                [weakManager loadNetworkSuccess:task request:request responseData:responseData];
            } failed:^(NSURLSessionDataTask *task, NSError *error) {
                [weakManager failWithRequest:request error:error];
            }];
        }
            break;
        default:
            break;
    }
}

#pragma mark - cache method
- (void)readCacheAndRequestData:(BGNetworkRequest *)request{
    __weak BGNetworkManager *weakManager = self;
    NSString *cacheKey = [BGNetworkUtil keyFromParamDic:request.parametersDic methodName:request.methodName baseURL:self.configuration.baseURL];
    [self.cache queryCacheForKey:cacheKey completed:^(NSData *data) {
        dispatch_async(weakManager.dataHandleQueue, ^{
            //解析数据
            id responseObject = [weakManager parseResponseData:data];
            dispatch_async(weakManager.workQueue, ^{
                if(responseObject){
                    [weakManager successWithRequest:request responseData:data responseObject:responseObject];
                    //读取缓存之后，再请求数据
                    if(request.cachePolicy == BGNetworkRequestCacheDataAndReadCacheLoadData){
                        [weakManager loadNetworkDataWithRequest:request];
                    }
                }
                else{
                    //请求网络
                    [weakManager loadNetworkDataWithRequest:request];
                }
            });
        });
    }];
}

- (void)cacheResponseData:(NSData *)responseData request:(BGNetworkRequest *)request{
    NSString *cacheKey = [BGNetworkUtil keyFromParamDic:request.parametersDic methodName:request.methodName baseURL:self.configuration.baseURL];
    //缓存数据
    [self.cache storeData:responseData forKey:cacheKey];
}

#pragma mark - set method
- (void)setNetworkConfiguration:(BGNetworkConfiguration *)configuration{
    NSParameterAssert(configuration);
    NSParameterAssert(configuration.baseURL);
    self.connector = [[BGNetworkConnector alloc] initWithBaseURL:configuration.baseURL delegate:self];
    _configuration = configuration;
}

#pragma mark - 网络请求回来调用的方法
- (void)loadNetworkSuccess:(NSURLSessionDataTask *)task request:(BGNetworkRequest *)request responseData:(NSData *)responseData{
    dispatch_async(self.dataHandleQueue, ^{
        //对数据进行解密
        NSData *decryptData = [self.configuration decryptResponseData:responseData response:task.response request:request];
        //解析数据
        id responseObject = [self parseResponseData:responseData];
        dispatch_async(self.workQueue, ^{
            if((request.cachePolicy == BGNetworkRequestCacheDataAndReadCacheOnly || request.cachePolicy == BGNetworkRequestCacheDataAndReadCacheLoadData) && [self.configuration isCacheResponseData:responseData response:task.response]){
                //缓存数据
                [self cacheResponseData:responseData request:request];
            }
            //成功回调
            [self successWithRequest:request responseData:decryptData responseObject:responseObject];
        });
    });
}

- (void)successWithRequest:(BGNetworkRequest *)request responseData:(NSData *)responseData responseObject:(id)responseObject{
    dispatch_async(self.dataHandleQueue, ^{
        id resultObject = nil;
        @try {
            //调用request方法中的数据处理，将数据处理成想要的model
            resultObject = [request processResponseObject:responseObject];
        }
        @catch (NSException *exception) {
            //崩溃则删除对应的缓存数据
            NSString *cacheKey = [BGNetworkUtil keyFromParamDic:request.parametersDic methodName:request.methodName baseURL:self.configuration.baseURL];
            [self.cache removeCacheForKey:cacheKey];
        }
        @finally {
        }
        //成功回调
        dispatch_async(dispatch_get_main_queue(), ^{
            [request.delegate request:request successWithResponse:resultObject];
        });
    });
}

- (void)failWithRequest:(BGNetworkRequest *)request error:(NSError *)error{
    dispatch_async(dispatch_get_main_queue(), ^{
        [request.delegate request:request failWithError:error];
    });
}

#pragma mark - cancel request
- (void)cancelRequestWithUrl:(NSString *)url{
    [self.connector cancelRequest:url];
}

#pragma mark - Util method
/**
 *  解析json数据
 */
- (id)parseResponseData:(NSData *)responseData{
    if(responseData == nil){
        return nil;
    }
    return [BGNetworkUtil parseJsonData:responseData];
}

- (NSString *)requestCompleteUrlWithMethodName:(NSString *)methodName{
    return [NSString stringWithFormat:@"%@%@", self.configuration.baseURL, methodName];
}

#pragma mark - BGNetworkConnectorDelegate
- (NSDictionary *)allHTTPHeaderFieldsWithNetworkConnector:(BGNetworkConnector *)connector request:(NSURLRequest *)request{
    //取出请求
    BGNetworkRequest *networkRequest = self.requestDic[request.URL.absoluteString];
    NSMutableDictionary *allHTTPHeaderFileds = [self.configuration.requestCommonHTTPHeaderFields mutableCopy];
    [networkRequest.requestHTTPHeaderFields enumerateKeysAndObjectsUsingBlock:^(NSString *key, id obj, BOOL *stop) {
        allHTTPHeaderFileds[key] = obj;
    }];
    return allHTTPHeaderFileds;
}

- (NSString *)queryStringForURLWithNetworkConnector:(BGNetworkConnector *)connector parameters:(NSDictionary *)paramters request:(NSURLRequest *)request{
    //取出请求
    BGNetworkRequest *networkRequest = self.requestDic[request.URL.absoluteString];
    return [self.configuration queryStringForURLWithRequest:networkRequest];
}

- (NSData *)dataOfHTTPBodyWithNetworkConnector:(BGNetworkConnector *)connector parameters:(NSDictionary *)paramters request:(NSURLRequest *)request error:(NSError *__autoreleasing *)error{
    BGNetworkRequest *networkRequest = self.requestDic[request.URL.absoluteString];
    return [self.configuration httpBodyDataWithRequest:networkRequest];
}
@end
