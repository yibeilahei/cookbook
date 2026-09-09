#import "WKWebView+Cookbook.h"
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

@interface CookbookPrintFinish : NSObject
@property (copy, nonatomic) void (^block)(BOOL success, NSError *_Nullable error);
- (void)printOperationDidRun:(NSPrintOperation *)op success:(BOOL)success contextInfo:(void *)info;
@end

@implementation CookbookPrintFinish
- (void)printOperationDidRun:(NSPrintOperation *)op success:(BOOL)success contextInfo:(void *)info
{
    void (^block)(BOOL, NSError *) = self.block;
    self.block = nil;
    if (!block)
        return;
    dispatch_async(dispatch_get_main_queue(), ^{
        block(success, nil);
    });
}
@end

static char kCookbookPrintFinishKey;

@interface WKWebView (CookbookPrivate)
- (void)_setPaginationMode:(NSInteger)mode;
- (void)_setPaginationBehavesLikeColumns:(BOOL)flag;
- (void)_setPageLength:(CGFloat)pageLength;
- (void)_setGapBetweenPages:(CGFloat)gap;
- (NSUInteger)_pageCount;
- (void)_doAfterNextPresentationUpdate:(void (^)(void))block;
- (void)_setBackgroundColor:(NSColor *)color;
- (void)_setDrawsBackground:(BOOL)draws;
- (void)_takePDFSnapshotWithConfiguration:(WKSnapshotConfiguration *)config
                        completionHandler:(void (^)(NSData *pdfSnapshotData, NSError *error))completion;
@end

@implementation WKWebView (Cookbook)

- (BOOL)cookbookHasPagination
{
    return [self respondsToSelector:@selector(_setPaginationMode:)]
        && [self respondsToSelector:@selector(_setPageLength:)]
        && [self respondsToSelector:@selector(_pageCount)];
}

- (void)cookbookSetPaginationMode:(NSInteger)mode
                       pageLength:(CGFloat)pageLength
                              gap:(CGFloat)gap
                      likeColumns:(BOOL)likeColumns
{
    if ([self respondsToSelector:@selector(_setPaginationMode:)])
        [self _setPaginationMode:mode];
    if ([self respondsToSelector:@selector(_setPaginationBehavesLikeColumns:)])
        [self _setPaginationBehavesLikeColumns:likeColumns];
    if ([self respondsToSelector:@selector(_setPageLength:)])
        [self _setPageLength:pageLength];
    if ([self respondsToSelector:@selector(_setGapBetweenPages:)])
        [self _setGapBetweenPages:gap];
}

- (NSUInteger)cookbookPageCount
{
    if (![self respondsToSelector:@selector(_pageCount)])
        return 0;
    return [self _pageCount];
}

- (void)cookbookSetWhiteBackground
{
    if ([self respondsToSelector:@selector(_setBackgroundColor:)])
        [self _setBackgroundColor:NSColor.whiteColor];
    if ([self respondsToSelector:@selector(_setDrawsBackground:)])
        [self _setDrawsBackground:YES];
}

- (void)cookbookDoAfterNextPaint:(void (^)(void))block
{
    if (!block)
        return;
    if ([self respondsToSelector:@selector(_doAfterNextPresentationUpdate:)])
        [self _doAfterNextPresentationUpdate:block];
    else
        block();
}

- (void)cookbookCapturePDFRect:(CGRect)rect
                    completion:(void (^)(NSData *_Nullable, NSError *_Nullable))completion
{
    if (!completion)
        return;
    WKSnapshotConfiguration *snap = [[WKSnapshotConfiguration alloc] init];
    snap.rect = rect;
    if ([self respondsToSelector:@selector(_takePDFSnapshotWithConfiguration:completionHandler:)]) {
        [self _takePDFSnapshotWithConfiguration:snap completionHandler:completion];
        return;
    }
    WKPDFConfiguration *pdf = [[WKPDFConfiguration alloc] init];
    pdf.rect = rect;
    [self createPDFWithConfiguration:pdf completionHandler:^(NSData *data, NSError *error) {
        completion(data, error);
    }];
}

- (void)cookbookPrintToFile:(NSURL *)url
                  paperSize:(NSSize)paperSize
                   fromPage:(NSInteger)fromPage
                     toPage:(NSInteger)toPage
                 completion:(void (^)(BOOL, NSError *_Nullable))completion
{
    if (!completion)
        return;
    if (!url.isFileURL) {
        completion(NO, [NSError errorWithDomain:@"Cookbook" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"print URL must be a file"}]);
        return;
    }
    NSWindow *win = self.window;
    if (!win) {
        completion(NO, [NSError errorWithDomain:@"Cookbook" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"WebKit view has no window"}]);
        return;
    }

    NSMutableDictionary *dict = [[[NSPrintInfo sharedPrintInfo] dictionary] mutableCopy];
    dict[NSPrintJobDisposition] = NSPrintSaveJob;
    dict[NSPrintJobSavingURL] = url;
    if (fromPage >= 1 && toPage >= fromPage) {
        dict[NSPrintAllPages] = @NO;
        dict[NSPrintFirstPage] = @(fromPage);
        dict[NSPrintLastPage] = @(toPage);
    } else {
        dict[NSPrintAllPages] = @YES;
    }
    NSPrintInfo *info = [[NSPrintInfo alloc] initWithDictionary:dict];
    info.paperSize = paperSize;
    info.topMargin = 0;
    info.bottomMargin = 0;
    info.leftMargin = 0;
    info.rightMargin = 0;
    info.orientation = NSPaperOrientationPortrait;
    info.horizontallyCentered = NO;
    info.verticallyCentered = NO;
    info.horizontalPagination = NSPrintingPaginationModeAutomatic;
    info.verticalPagination = NSPrintingPaginationModeAutomatic;
    info.scalingFactor = 1;

    NSPrintOperation *op = [self printOperationWithPrintInfo:info];
    op.showsPrintPanel = NO;
    op.showsProgressPanel = NO;
    // Must be YES: printing on the main thread deadlocks WebKit IPC.
    // Long jobs are split into page ranges in Swift so WKPrintingView
    // does not PAC-trap on a huge vertical-rl PDF.
    op.canSpawnSeparateThread = YES;
    op.view.frame = NSMakeRect(0, 0, paperSize.width, paperSize.height);

    CookbookPrintFinish *done = [[CookbookPrintFinish alloc] init];
    done.block = completion;
    objc_setAssociatedObject(self, &kCookbookPrintFinishKey, done, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [op runOperationModalForWindow:win
                          delegate:done
                    didRunSelector:@selector(printOperationDidRun:success:contextInfo:)
                       contextInfo:NULL];
}

@end
