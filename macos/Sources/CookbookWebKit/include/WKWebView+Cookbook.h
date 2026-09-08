#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WKWebView (Cookbook)

- (BOOL)cookbookHasPagination;
- (void)cookbookSetPaginationMode:(NSInteger)mode
                       pageLength:(CGFloat)pageLength
                              gap:(CGFloat)gap
                      likeColumns:(BOOL)likeColumns;
@property (nonatomic, readonly) NSUInteger cookbookPageCount;
- (void)cookbookSetWhiteBackground;
/// Calls WebKit's next-paint hook if present; otherwise runs the block immediately.
- (void)cookbookDoAfterNextPaint:(void (^)(void))block NS_SWIFT_NAME(cookbookOnNextPaint(_:));

@end

NS_ASSUME_NONNULL_END
