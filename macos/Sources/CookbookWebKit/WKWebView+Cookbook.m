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

@end
