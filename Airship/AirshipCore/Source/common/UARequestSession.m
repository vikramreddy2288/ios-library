/* Copyright Airship and Contributors */


#import "UARequestSession.h"
#import "UAURLRequestOperation+Internal.h"
#import "UADelayOperation+Internal.h"
#import "UARuntimeConfig.h"
#import "UAirship.h"

@interface UARequestSession()
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSOperationQueue *queue;
@property(nonatomic, strong) NSMutableDictionary *headers;
@end

static NSTimeInterval const InitialDelay = 30;
static NSTimeInterval const MaxBackOff = 3000;

@implementation UARequestSession

- (instancetype)initWithConfig:(UARuntimeConfig *)config session:(NSURLSession *)session queue:(NSOperationQueue *)queue {
    self = [super init];

    if (self) {
        self.headers = [NSMutableDictionary dictionary];
        self.session = session;
        self.queue = queue;

        [self setValue:@"gzip;q=1.0, compress;q=0.5" forHeader:@"Accept-Encoding"];
        [self setValue:[UARequestSession userAgentWithAppKey:config.appKey] forHeader:@"User-Agent"];
    }

    return self;
}

+ (instancetype)sessionWithConfig:(UARuntimeConfig *)config {

    static dispatch_once_t onceToken;
    static NSURLSession *_session;
    dispatch_once(&onceToken, ^{
        NSURLSessionConfiguration *sessionConfig = [NSURLSessionConfiguration defaultSessionConfiguration];

        // Disable the default HTTP cache so that 304 responses can be received. API clients using
        // UARequestSession are expected to provide their own caching.
        sessionConfig.URLCache = nil;
        sessionConfig.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;

        // Force min 1.2 even though our backend will always negotiate 1.2+
        sessionConfig.TLSMinimumSupportedProtocol = kTLSProtocol12;

        _session = [NSURLSession sessionWithConfiguration:sessionConfig delegate:nil delegateQueue:nil];
    });

    NSOperationQueue *queue = [[NSOperationQueue alloc] init];
    queue.maxConcurrentOperationCount = 1;

    return [[UARequestSession alloc] initWithConfig:config session:_session queue:queue];
}

+ (instancetype)sessionWithConfig:(UARuntimeConfig *)config NSURLSession:(NSURLSession *)session {
    NSOperationQueue *queue = [[NSOperationQueue alloc] init];
    queue.maxConcurrentOperationCount = 1;

    return [[UARequestSession alloc] initWithConfig:config session:session queue:queue];
}

+ (instancetype)sessionWithConfig:(UARuntimeConfig *)config NSURLSession:(NSURLSession *)session queue:(NSOperationQueue *)queue {
    return [[UARequestSession alloc] initWithConfig:config session:session queue:queue];
}

- (void)setValue:(id)value forHeader:(NSString *)field {
    [self.headers setValue:value forKey:field];
}

- (void)dataTaskWithRequest:(UARequest *)request
          completionHandler:(UARequestCompletionHandler)completionHandler {

    [self dataTaskWithRequest:request retryWhere:nil completionHandler:completionHandler];
}

- (void)dataTaskWithRequest:(UARequest *)request
                 retryWhere:(UARequestRetryBlock)retryBlock
          completionHandler:(UARequestCompletionHandler)completionHandler {

    // Create the URLRequest
    NSMutableURLRequest *urlRequest = [NSMutableURLRequest requestWithURL:request.URL];
    [urlRequest setHTTPShouldHandleCookies:NO];
    [urlRequest setHTTPMethod:request.method];
    [urlRequest setHTTPBody:request.body];

    // Session Headers
    for (NSString *key in self.headers) {
        [urlRequest setValue:self.headers[key] forHTTPHeaderField:key];
    }

    // Request Headers
    for (NSString *key in request.headers) {
        [urlRequest setValue:request.headers[key] forHTTPHeaderField:key];
    }

    NSOperation *operation = [self operationWithRequest:urlRequest
                                             retryDelay:InitialDelay
                                             retryWhere:retryBlock
                                      completionHandler:completionHandler];

    [self.queue addOperation:operation];
}

- (void)cancelAllRequests {
    [self.queue cancelAllOperations];
}

- (NSOperation *)operationWithRequest:(NSURLRequest *)request
                           retryDelay:(NSTimeInterval)retryDelay
                           retryWhere:(BOOL (^)(NSData *data, NSURLResponse *response))retryBlock
                    completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {


    UAURLRequestOperation *operation = [UAURLRequestOperation operationWithRequest:request
                                                                           session:self.session
                                                                 completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {

        if (!error && retryBlock && retryBlock(data, response)) {
            UADelayOperation *delayOperation = [UADelayOperation operationWithDelayInSeconds:retryDelay];
            NSOperation *retryOperation = [self operationWithRequest:request
                                                          retryDelay:MIN(retryDelay * 2, MaxBackOff)
                                                          retryWhere:retryBlock
                                                   completionHandler:completionHandler];

            [retryOperation addDependency:delayOperation];

            [self.queue addOperation:delayOperation];
            [self.queue addOperation:retryOperation];

            return;
        } else {
            completionHandler(data, response, error);
        }

    }];
    
    return operation;
}


+ (NSString *)userAgentWithAppKey:(NSString *)appKey {
    /*
     * [LIB-101] User agent string should be:
     * App 1.0 (iPad; iPhone OS 5.0.1; UALib 1.1.2; <app key>; en_US)
     */

    UIDevice *device = [UIDevice currentDevice];

    NSBundle *bundle = [NSBundle mainBundle];
    NSDictionary *info = [bundle infoDictionary];

    NSString *appName = [info objectForKey:(NSString*)kCFBundleNameKey];
    NSString *appVersion = [info objectForKey:@"CFBundleShortVersionString"];

    NSString *deviceModel = [device model];
    NSString *osName = [device systemName];
    NSString *osVersion = [device systemVersion];

    NSString *libVersion = [UAirshipVersion get];
    NSString *locale = [[NSLocale autoupdatingCurrentLocale] localeIdentifier];

    return [NSString stringWithFormat:@"%@ %@ (%@; %@ %@; UALib %@; %@; %@)",
            appName, appVersion, deviceModel, osName, osVersion, libVersion, appKey, locale];
}

@end
