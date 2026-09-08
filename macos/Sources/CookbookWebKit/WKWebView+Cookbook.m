#import "WKWebView+Cookbook.h"
#import <AppKit/AppKit.h>

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

@end
