//
//  F2AppWebView.m
//  F2 Demo
//
//  Created by Nathan Johnson on 3/20/14.
//  Updated by Mark Manes on 1/27/16
//  Copyright (c) 2014,2015,2016 Markit. All rights reserved.
//

#import "F2AppView.h"


@interface F2AppView()
@property (nonatomic, strong) UIWebView *webView; // the webview for the F2 App
@property (nonatomic, strong) WKWebView *webViewWK; // the webview for iOS 8 and better

@property (nonatomic, strong) NSMutableDictionary *appConfig; //The app configuration, this is passed from the user and parsed into the dictionary
@property (nonatomic, strong) NSString *appName;   // the app name
@property (nonatomic, strong) NSURL *manifestURL;  // The url to get the app manifest from
@property (nonatomic, strong) NSString *appData;   // extra data. this data gets passed back to the app on init
@property (nonatomic, strong) NSDictionary *appManifest; // The manifest retrieved from the URL, the manifest contains everything we need to build the html
@property (nonatomic, strong) NSString *appHTML;   // the body of html
@property (nonatomic, strong) NSString *appStatus; // the status of the request for the manifest
@property (nonatomic, strong) NSString *appStatusMessage; // status message
@property (nonatomic, strong) NSString *appID;  // the app id
@property (nonatomic, strong) NSArray *scripts; // javascript URLs to load into the html
@property (nonatomic, strong) NSArray *inlineScripts; // inline javascript to insert into the html
@property (nonatomic, strong) NSArray *styles;  // stylesheet URLs to load into the html

// these are the strings of javascript that will get called at the
// end of the html, registering the events that the user wants to listen to
@property (nonatomic, strong) NSMutableArray *eventRegesteringStrings;

//the session task currently getting data
@property (nonatomic, strong) NSURLSessionDataTask *sessionTask;

// Use newer webkit / nitro engine
@property (nonatomic, assign) BOOL useWebKit;
@end

@implementation F2AppView

-(id)initWithFrame:(CGRect)frame{
    self = [super initWithFrame:frame];
    if (self) {
        //set defaults
        self.useWebKit = false;
        self.userScalable=NO;
        self.scrollable=NO;
        self.shouldOpenLinksExternally=YES;
        self.scale=1.0f;
        self.eventRegesteringStrings = [NSMutableArray new];
        
        if (NSClassFromString(@"WKWebView"))
            self.useWebKit = true;
        
        //create web view
        self.useWebKit = YES;
        if (self.useWebKit) {
            NSLog(@"*** using Webkit");
            WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
            WKUserContentController *controller = [[WKUserContentController alloc] init];
            [controller addScriptMessageHandler:self name:@"observe"];
            configuration.userContentController = controller;
            self.webViewWK = [[WKWebView alloc]initWithFrame:CGRectMake(0, 0, frame.size.width, frame.size.height) configuration:configuration];
            [self.webViewWK.scrollView setScrollEnabled:NO];
//            [self.webViewWK setScalesPageToFit:YES];
            [self.webViewWK setAutoresizingMask:UIViewAutoresizingFlexibleHeight|UIViewAutoresizingFlexibleWidth];
            [self.webViewWK setNavigationDelegate:self];
            [self.webViewWK setBackgroundColor:[UIColor clearColor]];
            [self addSubview:self.webViewWK];
        }
        else {
            self.webView = [[UIWebView alloc]initWithFrame:CGRectMake(0, 0, frame.size.width, frame.size.height)];
            [self.webView.scrollView setScrollEnabled:NO];
            [self.webView setScalesPageToFit:YES];
            [self.webView setAutoresizingMask:UIViewAutoresizingFlexibleHeight|UIViewAutoresizingFlexibleWidth];
            [self.webView setDelegate:self];
            [self.webView setBackgroundColor:[UIColor clearColor]];
            [self addSubview:self.webView];
        }

    }
    return self;
}

#pragma mark - Public Methods
-(NSError*)setAppJSONConfig:(NSString*)config{
    NSError* error;
    //parse te configuration file
    NSArray* parsedFromJSON = [NSJSONSerialization JSONObjectWithData:[config dataUsingEncoding:NSUTF8StringEncoding] options:kNilOptions error:&error];
    if (!error){
        //configuration comes in as an array with a single object, the one object is a dictionary with the configuration data
        self.appConfig = [NSMutableDictionary dictionaryWithDictionary:[parsedFromJSON objectAtIndex:0]];
        
        //we take the configuration, package it into a URL request and send back to the URL that is in the configuration
        NSString* encodedString = [config stringByAddingPercentEscapesUsingEncoding:NSASCIIStringEncoding];
        if (self.appConfig [@"manifestUrl"]) {
            //if the configuration contains a URL
            self.manifestURL = [NSURL URLWithString:[NSString stringWithFormat:@"%@/json?params=%@",self.appConfig [@"manifestUrl"],encodedString]];
        }
        else{
            //send an error if no URL
            NSMutableDictionary *errorDetail = [NSMutableDictionary dictionary];
            [errorDetail setValue:[NSString stringWithFormat:@"missing manifestUrl in config"] forKey:NSLocalizedDescriptionKey];
            error = [NSError errorWithDomain:@"F2AppView" code:100 userInfo:errorDetail];
        }
        
        //if "name" exists in configuration, we keep it in our ivar
        if (self.appConfig [@"name"]) {
            self.appName = self.appConfig [@"name"];
        }else{
            self.appName = NULL;
        }
    }
    return error;
}


-(void)registerEvent:(NSString*)event key:(NSString*)key dataValueGetter:(NSString*)dataValueGetter{
    [self.eventRegesteringStrings addObject:[NSString stringWithFormat:@"F2.Events.on(%@, function(data){sendMessageToNativeMobileApp('%@',%@)});",event,key,dataValueGetter]];
}

-(void)setScrollable:(BOOL)scrollable{
    if (self.useWebKit) {
        [self.webViewWK.scrollView setScrollEnabled:scrollable];
    }
    else
        [self.webView.scrollView setScrollEnabled:scrollable];
}

-(void)loadApp{
    if (self.manifestURL) {
        //cancel the current task if it is running
        [self.sessionTask cancel];
        
        //build new request
        NSURLRequest* request = [NSURLRequest requestWithURL:self.manifestURL];
        NSURLSession* session = [NSURLSession sharedSession];
        self.sessionTask = [session dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
            //our return block after the request was made
            if (!error){
                //parse the data we get back from the request for a manifest
                NSDictionary* parsedFromJSON = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:&error];
                if (!error){
                    //we have a manifest! we can now try to build the HTML
                    self.appManifest = parsedFromJSON;
                    NSArray* apps = self.appManifest[@"apps"];
                    NSDictionary* app = [apps firstObject];
                    if (app[@"status"]) {
                        self.appStatus = app[@"status"];
                        if ([self.appStatus isEqualToString:@"SUCCESS"]) {
                            //Status is "SUCCESS", so we have all we need to build the app html
                            
                            //load in the data
                            self.appHTML = app[@"html"];
                            self.appID = app[@"id"];
                            self.appStatusMessage = app[@"statusMessage"];
                            self.appData = app[@"data"];
                            self.inlineScripts = self.appManifest[@"inlineScripts"];
                            self.scripts = self.appManifest[@"scripts"];
                            self.styles = self.appManifest[@"styles"];
                            
                            /*** This is where we build the full html to put into the web view ***/
                            NSString* htmlContent = [NSString stringWithFormat:@"%@%@%@",[self header],[self body],[self footer]];
                            
                            //log the generated html
                            NSLog(@"GENERATED %@ HTML:\n%@\n\n",self.appName,htmlContent);
                            
                            //Put our newly made html into the webview to load
                            if (self.useWebKit) {
                                [self.webViewWK loadHTMLString:htmlContent baseURL:nil];
                            }
                            else
                                [self.webView loadHTMLString:htmlContent baseURL:nil];
                        }
                        else{
                            //Manifest status was not SUCCESS
                            NSMutableDictionary *errorDetail = [NSMutableDictionary dictionary];
                            [errorDetail setValue:[NSString stringWithFormat:@"Manifest Status:%@",self.appStatus] forKey:NSLocalizedDescriptionKey];
                            error = [NSError errorWithDomain:@"F2AppView" code:100 userInfo:errorDetail];
                        }
                    }
                    else{
                        // we didn't get a "status" element in the manifest.
                        NSMutableDictionary *errorDetail = [NSMutableDictionary dictionary];
                        [errorDetail setValue:[NSString stringWithFormat:@"Unrecognised Manifest Format"] forKey:NSLocalizedDescriptionKey];
                        error = [NSError errorWithDomain:@"F2AppView" code:100 userInfo:errorDetail];
                    }
                }
            }
            //loading was completed, let's tell our delegate and pass it whatever error we collected
            if ([self.delegate respondsToSelector:@selector(F2View:appFinishedLoading:)]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.delegate F2View:self appFinishedLoading:error];
                });
            }
        }];
        //start the request
        [self.sessionTask resume];
    }
}

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    
    // Log out the message received
    NSLog(@"Received event %@", message.body);
    
    // Then pull something from the device using the message body
    NSString *version = [[UIDevice currentDevice] valueForKey:message.body];
    
    // Execute some JavaScript using the result
    NSString *exec_template = @"set_headline(\"received: %@\");";
    NSString *exec = [NSString stringWithFormat:exec_template, version];
    [self.webViewWK evaluateJavaScript:exec completionHandler:nil];
}

-(void)sendJavaScript:(NSString*)javaScript{
    if (self.useWebKit) {
        [self.webViewWK evaluateJavaScript:javaScript completionHandler:nil];
    }
    else {
        [self.webView stringByEvaluatingJavaScriptFromString:javaScript];
    }
    return;
}

#pragma mark - String Construction
-(NSString*)header{
    //build the html header
    NSMutableString* headContent = [NSMutableString new];
    [headContent appendString:@"<!DOCTYPE html><html lang='en'><head><meta charset='utf-8'><title>F2 App</title>"];
    [headContent appendFormat:@"<meta name='viewport' content='initial-scale=%0.2f, user-scalable=%@'>",self.scale,(self.userScalable)?@"YES":@"NO"];
    [headContent appendString:@"<link href='http://maxcdn.bootstrapcdn.com/bootstrap/3.2.0/css/bootstrap.min.css' rel='stylesheet'>"];
    [headContent appendString:@"<link rel='stylesheet' href='//ajax.googleapis.com/ajax/libs/jqueryui/1.10.4/themes/smoothness/jquery-ui.css' />"];
    
    //add the styles from the manifest
    if (self.styles) {
        for (NSString* styleResourceURL in self.styles) {
            [headContent appendFormat:@"<link href='%@' rel='stylesheet'>",styleResourceURL];
        }
    }
    
    //add CSS from user
    if (self.additionalCss) {
        [headContent appendFormat:@"<style>%@</style>",self.additionalCss];
    }
    
    //close header
    [headContent appendString:@"</head>"];
    return headContent;
}

-(NSString*)body{
    NSMutableString* bodyContent = [NSMutableString new];
    //note: we open <body> here, but the footer will be the one closing it
    [bodyContent appendFormat:@"<body><div class='container'><div class='row'><div class='col-md-12'><section id='iOS-F2-App' class='f2-app %@' style='position:static;'>",self.appID];
    
    if (self.appName) {
        [bodyContent appendFormat:@"<header class='clearfix'><h3 class='f2-app-title'>%@</h3></header>",self.appName];
    }else{
        //we'll make the <header> anyways, the app might populate it
        [bodyContent appendString:@"<header class='clearfix'><h3 class='f2-app-title'></h3></header>"];
    }
    
    /*** here we put in the html that we get from the manifest ***/
    [bodyContent appendString:self.appHTML];
    
    //close our elements
    [bodyContent appendString:@"</div></section></div></div></div>"];
    
    return bodyContent;
}

-(NSString*)footer{
    //Buld the footer for the html
    NSMutableString* footerContent =[NSMutableString string];
    
    //common scripts
    [footerContent appendString:@"<script src='http://code.jquery.com/jquery-2.1.1.min.js'></script>"];
    [footerContent appendString:@"<script src='http://maxcdn.bootstrapcdn.com/bootstrap/3.2.0/js/bootstrap.min.js'></script>"];
    [footerContent appendString:@"<script src='http://ajax.googleapis.com/ajax/libs/jqueryui/1.10.4/jquery-ui.min.js'></script>"];
    [footerContent appendString:@"<script type='text/javascript' src='https://cdnjs.cloudflare.com/ajax/libs/F2/1.4.0/f2.min.js'></script>"];
    
    //inline scriptURLs from the manifest
    if (self.scripts) {
        for (NSString* jsResourceURL in self.scripts) {
            [footerContent appendFormat:@"<script type='text/javascript' src='%@'></script>",jsResourceURL];
        }
    }
    
    //register app (javascript)
    [footerContent appendString:[self jSRegisterApp]];
    
    //declair the method that can "talk" back to us
    [footerContent appendString:[self jSMessageSend]];
    
    //register any F2 events we are told to listen to
    [footerContent appendString:[self jsRegisterEvents]];
    
    //close html
    [footerContent appendString:@"</body></html>"];
    return footerContent;
}

-(NSString*)jSRegisterApp{
    //add "root" to config and rebuild JSON
    [self.appConfig  setValue:@"#iOS-F2-App" forKey:@"root"];
    [self.appConfig  setValue:self.appData  forKey:@"data"];
    NSString* jsonConfig = [self JSONStringFromDictionary:self.appConfig ];
    //this javascript will register tha app and send it the configuration
    NSString* jsFunction = [NSString stringWithFormat:
                                @"  <script type='text/javascript'>\
                                        var _appConfig = %@ ;\
                                        $(function(){\
                                        F2.init();\
                                        F2.registerApps(_appConfig);\
                                        });\
                                    </script>",jsonConfig];
    return jsFunction;
}

-(NSString*)jSMessageSend{
    /*  this declairs a javascript function called sendMessageToNativeMobileApp in the webview for the js in the view to communicate with us
        This works by trying to load up an iframe with the message included in its attributes. We will catch this using the webview
        delegate method webView:shouldStartLoadWithRequest:navigationType: */
    NSString* jsFunction = @"  <script type='text/javascript'>                                                              \
                                    var sendMessageToNativeMobileApp = function(_key, _val) {                               \
                                        var iframe = document.createElement('IFRAME');                                      \
                                        iframe.setAttribute(\"src\", _key + \":##sendMessageToNativeMobileApp##\" + _val);  \
                                        document.documentElement.appendChild(iframe);                                       \
                                        iframe.parentNode.removeChild(iframe);                                              \
                                        iframe = null;                                                                      \
                                    };                                                                                      \
                                </script>                                                                                   ";
    return jsFunction;
}

-(NSString*)jsRegisterEvents{
    //this will generate javascript elements that will register all F2 events declaired in self.eventRegesteringStrings
    NSMutableString* eventRegisteringJS = [NSMutableString stringWithString:@"<script>"];
    for (NSString* eventRegister in self.eventRegesteringStrings) {
        [eventRegisteringJS appendString:eventRegister];
    }
    [eventRegisteringJS appendString:@"</script>"];
    return eventRegisteringJS;
}

#pragma mark - UIWebViewDelegate methods
- (BOOL)webView:(UIWebView*)webView shouldStartLoadWithRequest:(NSURLRequest*)request navigationType:(UIWebViewNavigationType)navigationType{
    //we use this delegate method to catch any instances of the sendMessageToNativeMobileApp javascript method and pass the data to our delegate
    NSString* requestString = [[[request URL] absoluteString] stringByReplacingPercentEscapesUsingEncoding: NSUTF8StringEncoding];
    NSArray* requestArray = [requestString componentsSeparatedByString:@":##sendMessageToNativeMobileApp##"];
    //if the array is bigger than 0, then we know that it wasn't an actual request, but from the javascript function we made called sendMessageToNativeMobileApp
    if ([requestArray count] > 1){
        NSString* requestPrefix = [[requestArray objectAtIndex:0] lowercaseString];
        NSString* requestMssg = ([requestArray count] > 0) ? [requestArray objectAtIndex:1] : @"";
        if (self.delegate) {
            if ([self.delegate respondsToSelector:@selector(F2View:messageRecieved:withKey:)]) {
                [self.delegate F2View:self messageRecieved:requestMssg withKey:requestPrefix];
            }
        }
        return NO;
    }
    else if (navigationType == UIWebViewNavigationTypeLinkClicked && self.shouldOpenLinksExternally) {
        //if we aren't supposed to open the link up in the web view, we'll open it in safari
        [[UIApplication sharedApplication] openURL:[request URL]];
        return NO;
    }
    return YES;
}

#pragma mark - helper methods
- (NSString*)stringByDecodingURLFormat:(NSString*)string{
    //URL decoded to normal string
    NSString* result = [string stringByReplacingOccurrencesOfString:@"+" withString:@" "];
    result = [result stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    return result;
}

- (NSString*)JSONStringFromDictionary:(NSDictionary*)dictionary{
    //dictionary converted into NSString
    NSString* jSONResult;
    NSError* error;
    NSData* jsonData = [NSJSONSerialization dataWithJSONObject:dictionary options:0 error:&error];
    NSAssert(!error, @"error generating JSON: %@", error);
    jSONResult = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    return jSONResult;
}
@end
