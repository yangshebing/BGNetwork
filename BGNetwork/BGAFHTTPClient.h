//
//  BGAFHTTPClient.h
//  BGNetwork
//
//  Created by user on 15/8/19.
//  Copyright (c) 2015年 lcg. All rights reserved.
//

#import "AFHTTPSessionManager.h"

@interface BGAFHTTPClient : AFHTTPSessionManager
/** 判断一组请求是否已经请求完成 */
- (BOOL)isHttpQueueFinished:(NSArray*)httpUrlArray;

/** 取消请求 */
- (void)cancelTasksWithUrl:(NSString *)url;
@end
