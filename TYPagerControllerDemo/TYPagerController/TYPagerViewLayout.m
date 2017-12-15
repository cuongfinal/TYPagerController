//
//  TYPagerViewLayout.m
//  TYPagerControllerDemo
//
//  Created by tanyang on 2017/7/9.
//  Copyright © 2017年 tany. All rights reserved.
//

#import "TYPagerViewLayout.h"
#import <objc/runtime.h>

@interface TYAutoPurgeCache : NSCache
@end

@implementation TYAutoPurgeCache

- (nonnull instancetype)init {
    if (self = [super init]) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(removeAllObjects) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
}
@end

static char ty_pagerReuseIdentifyKey;

@implementation NSObject (TY_PagerReuseIdentify)

- (NSString *)ty_pagerReuseIdentify {
    return objc_getAssociatedObject(self, &ty_pagerReuseIdentifyKey);
}

- (void)setTy_pagerReuseIdentify:(NSString *)ty_pagerReuseIdentify {
    objc_setAssociatedObject(self, &ty_pagerReuseIdentifyKey, ty_pagerReuseIdentify, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end

typedef NS_ENUM(NSUInteger, TYPagerScrollingDirection) {
    TYPagerScrollingLeft,
    TYPagerScrollingRight,
};

NS_INLINE CGRect frameForItemAtIndex(NSInteger index, CGRect frame)
{
    return CGRectMake(index * CGRectGetWidth(frame), 0, CGRectGetWidth(frame), CGRectGetHeight(frame));
}

// caculate visilble range in offset
NS_INLINE NSRange visibleRangWithOffset(CGFloat offset,CGFloat width, NSInteger maxIndex)
{
    if (width <= 0) {
        return NSMakeRange(0, 0);
    }
    NSInteger startIndex = offset/width;
    NSInteger endIndex = ceil((offset + width)/width);
    
    if (startIndex < 0) {
        startIndex = 0;
    } else if (startIndex > maxIndex) {
        startIndex = maxIndex;
    }
    
    if (endIndex > maxIndex) {
        endIndex = maxIndex;
    }
    
    NSUInteger length = endIndex - startIndex;
    if (length > 5) {
        length = 5;
    }
    return NSMakeRange(startIndex, length);
}

NS_INLINE NSRange prefetchRangeWithVisibleRange(NSRange visibleRange,NSInteger prefetchItemCount, NSInteger  countOfPagerItems) {
    if (prefetchItemCount <= 0) {
        return NSMakeRange(0, 0);
    }
    NSInteger leftIndex = MAX((NSInteger)visibleRange.location - prefetchItemCount, 0);
    NSInteger rightIndex = MIN(visibleRange.location+visibleRange.length+prefetchItemCount, countOfPagerItems);
    return NSMakeRange(leftIndex, rightIndex - leftIndex);
}

static const NSInteger kMemoryCountLimit = 16;

@interface TYPagerViewLayout<ItemType> ()<UIScrollViewDelegate> {
    // Private
    BOOL        _needLayoutContent;
    BOOL        _scrollAnimated;
    BOOL        _isTapScrollMoved;
    CGFloat     _preOffsetX;
    NSInteger   _firstScrollToIndex;
    BOOL        _didLayoutSubViews;
    
    struct {
        unsigned int addVisibleItem :1;
        unsigned int removeInVisibleItem :1;
    }_dataSourceFlags;
    
    struct {
        unsigned int transitionFromIndexToIndex :1;
        unsigned int transitionFromIndexToIndexProgress :1;
        unsigned int pagerViewLayoutDidScroll: 1;
    }_delegateFlags;

}

// UI

@property (nonatomic, strong) UIScrollView *scrollView;

// Data

@property (nonatomic, assign) NSInteger countOfPagerItems;
@property (nonatomic, assign) NSInteger curIndex;

@property (nonatomic, strong) NSCache<NSNumber *,ItemType> *memoryCache;

@property (nonatomic, assign) NSRange visibleRange;
@property (nonatomic, assign) NSRange prefetchRange;

@property (nonatomic, strong) NSDictionary<NSNumber *,ItemType> *visibleIndexItems;
@property (nonatomic, strong) NSDictionary<NSNumber *,ItemType> *prefetchIndexItems;
@property (nonatomic, strong) NSDictionary<NSNumber *,ItemType> *allItems;

//reuse Class and nib
@property (nonatomic, strong) NSMutableDictionary *reuseIdentifyClassOrNib;
// reuse items
@property (nonatomic, strong) NSMutableDictionary *reuseIdentifyItems;

@end

static NSString * kScrollViewFrameObserverKey = @"scrollView.frame";

@implementation TYPagerViewLayout

#pragma mark - init

- (instancetype)initWithScrollView:(UIScrollView *)scrollView {
    if (self = [super init]) {
        NSParameterAssert(scrollView!=nil);
        _scrollView = scrollView;
        
        [self configurePropertys];
        
        [self configureScrollView];
    }
    return self;
}

#pragma mark - configure

- (void)configurePropertys {
    _scrollView.contentSize =  CGSizeMake(_scrollView.frame.size.width * 2,
                                          _scrollView.contentSize.height);
    _curIndex = NSNotFound;
    _preOffsetX = 0;
    _changeIndexWhenScrollProgress = 0.5;
    _didLayoutSubViews = NO;
    _firstScrollToIndex = 0;
    _prefetchItemWillAddToSuperView = NO;
    _addVisibleItemOnlyWhenScrollAnimatedEnd = NO;
    _progressAnimateEnabel = YES;
    _adjustScrollViewInset = YES;
    _scrollAnimated = YES;
    _autoMemoryCache = YES;
}

- (void)configureScrollView {
    _scrollView.showsHorizontalScrollIndicator = NO;
    _scrollView.showsVerticalScrollIndicator = NO;
    _scrollView.pagingEnabled = YES;
    _scrollView.delegate = self;
}

- (void)resetPropertys {
    _scrollAnimated = NO;
    _preOffsetX = 0;
}

#pragma mark - getter setter

- (NSArray *)visibleItems {
    return _visibleIndexItems.allValues;
}

- (NSArray *)visibleIndexs {
    return _visibleIndexItems.allKeys;
}

- (NSMutableDictionary *)reuseIdentifyItems {
    if (!_reuseIdentifyItems) {
        _reuseIdentifyItems = [NSMutableDictionary dictionary];
    }
    return _reuseIdentifyItems;
}

- (NSMutableDictionary *)reuseIdentifyClassOrNib {
    if (!_reuseIdentifyClassOrNib) {
        _reuseIdentifyClassOrNib = [NSMutableDictionary dictionary];
    }
    return _reuseIdentifyClassOrNib;
}

- (void)setPrefetchItemCount:(NSInteger)prefetchItemCount {
    _prefetchItemCount = prefetchItemCount;
    if (prefetchItemCount <= 0 && _prefetchIndexItems) {
        _prefetchIndexItems = nil;
    }
}

- (void)setDataSource:(id<TYPagerViewLayoutDataSource>)dataSource {
    _dataSource = dataSource;
    _dataSourceFlags.addVisibleItem = [dataSource respondsToSelector:@selector(pagerViewLayout:addVisibleItem:atIndex:)];
    _dataSourceFlags.removeInVisibleItem = [dataSource respondsToSelector:@selector(pagerViewLayout:removeInVisibleItem:atIndex:)];
}

- (void)setDelegate:(id<TYPagerViewLayoutDelegate>)delegate {
    _delegate = delegate;
    _delegateFlags.transitionFromIndexToIndex = [delegate respondsToSelector:@selector(pagerViewLayout:transitionFromIndex:toIndex:animated:)];
    _delegateFlags.transitionFromIndexToIndexProgress = [delegate respondsToSelector:@selector(pagerViewLayout:transitionFromIndex:toIndex:progress:)];
    _delegateFlags.pagerViewLayoutDidScroll = [delegate respondsToSelector:@selector(pagerViewLayoutDidScroll:)];
}

#pragma mark - public

- (void)reloadData {
    [self resetPropertys];
    [self updateData];
}

- (void)updateData {
    _countOfPagerItems = [_dataSource numberOfItemsInPagerViewLayout];
    [self loadAllController];
    [self setNeedLayout];
}

/**
 scroll to item at index
 */
- (void)scrollToItemAtIndex:(NSInteger)index animate:(BOOL)animate {
    if (index < 0 || index >= _countOfPagerItems) {
        return;
    }
    
    if (!_didLayoutSubViews && CGRectIsEmpty(_scrollView.frame)) {
        _firstScrollToIndex = index;
    }
    
    [self scrollViewWillScrollToView:_scrollView animate:animate];
    [_scrollView setContentOffset:CGPointMake((index + 1) * CGRectGetWidth(_scrollView.frame),0) animated:NO];
    [self scrollViewDidScrollToView:_scrollView animate:animate];
}

- (UIView *)viewForItem:(id)item atIndex:(NSInteger)index {
    UIView *view = [_dataSource pagerViewLayout:self viewForItem:item atIndex:index];
    return view;
}

- (CGRect)frameForItemAtIndex:(NSInteger)index {
    CGRect frame = frameForItemAtIndex(index, _scrollView.frame);
    if (_adjustScrollViewInset) {
        frame.size.height -= _scrollView.contentInset.top;
    }
    return frame;
}

#pragma mark - register && dequeue

- (void)registerClass:(Class)Class forItemWithReuseIdentifier:(NSString *)identifier {
    [self.reuseIdentifyClassOrNib setObject:Class forKey:identifier];
}

- (void)registerNib:(UINib *)nib forItemWithReuseIdentifier:(NSString *)identifier {
    [self.reuseIdentifyClassOrNib setObject:nib forKey:identifier];
}

- (id)dequeueReusableItemWithReuseIdentifier:(NSString *)identifier forIndex:(NSInteger)index {
    NSAssert(_reuseIdentifyClassOrNib.count != 0, @"you don't register any identifiers!");
    NSObject *item = [self.reuseIdentifyItems objectForKey:identifier];
    if (item) {
        [self.reuseIdentifyItems removeObjectForKey:identifier];
        return item;
    }
    id itemClassOrNib = [self.reuseIdentifyClassOrNib objectForKey:identifier];
    if (!itemClassOrNib) {
        NSString *error = [NSString stringWithFormat:@"you don't register this identifier->%@",identifier];
        NSAssert(NO, error);
        NSLog(@"%@", error);
        return nil;
    }
    
    if (class_isMetaClass(object_getClass(itemClassOrNib))) {
        // is class
        item = [[((Class)itemClassOrNib) alloc]init];
    }else if ([itemClassOrNib isKindOfClass:[UINib class]]) {
        // is nib
        item =[((UINib *)itemClassOrNib)instantiateWithOwner:nil options:nil].firstObject;
    }
    if (!item){
        NSString *error = [NSString stringWithFormat:@"you register identifier->%@ is not class or nib!",identifier];
        NSAssert(NO, error);
        NSLog(@"%@", error);
        return nil;
    }
    [item setTy_pagerReuseIdentify:identifier];
    UIView *view = [_dataSource pagerViewLayout:self viewForItem:item atIndex:index];
    view.frame = [self frameForItemAtIndex:index];
    return item;
}

- (void)enqueueReusableItem:(NSObject *)reuseItem prefetchRange:(NSRange)prefetchRange atIndex:(NSInteger)index{
    if (reuseItem.ty_pagerReuseIdentify.length == 0 || NSLocationInRange(index, prefetchRange)) {
        return;
    }
    [self.reuseIdentifyItems setObject:reuseItem forKey:reuseItem.ty_pagerReuseIdentify];
}

#pragma mark - layout content

- (void)setNeedLayout {
    // 1. get count Of pager Items
    if (_countOfPagerItems <= 0) {
        _countOfPagerItems = [_dataSource numberOfItemsInPagerViewLayout];
    }
    _needLayoutContent = YES;
    
    BOOL needLayoutSubViews = NO;
    if (!_didLayoutSubViews && !CGRectIsEmpty(_scrollView.frame) && _firstScrollToIndex < _countOfPagerItems) {
        _didLayoutSubViews = YES;
        needLayoutSubViews = YES;
    }
    
    // 2.set contentSize and offset
    CGFloat contentWidth = CGRectGetWidth(_scrollView.frame);
    _scrollView.contentSize = CGSizeMake(contentWidth * (_countOfPagerItems + 2), _scrollView.contentSize.height);
    _scrollView.contentOffset = [self createPoint:contentWidth * 2];;
    [self layoutIfNeed:0];
}
- (CGPoint) createPoint:(CGFloat) size {
        return CGPointMake(size, 0);
}
- (void)layoutIfNeed:(NSInteger)index {
    if (CGRectIsEmpty(_scrollView.frame)) {
        return;
    }
    if (index == _curIndex) return;
    _curIndex = index;
    _needLayoutContent = NO;
    
    NSInteger prevPage = [self pageIndexByAdding:-1 from:_curIndex];
    NSInteger nextPage = [self pageIndexByAdding:+1 from:_curIndex];
    
    [self removeControllerInScrollView];
    [self loadControllerAtIndex:_curIndex andPlaceAtIndex:0];
    // Pre-load the content for the adjacent pages if multiple pages are to be displayed
    [self loadControllerAtIndex:prevPage andPlaceAtIndex:-1];   // load previous page
    [self loadControllerAtIndex:nextPage andPlaceAtIndex:1];   // load next page
    
    CGFloat size = _scrollView.frame.size.width;
    _scrollView.contentOffset = [self createPoint:size * 2]; // recenter
}

-(void)loadAllController{
    NSMutableDictionary *items = [NSMutableDictionary dictionary];
    for (NSInteger idx = 0 ; idx < _countOfPagerItems; ++idx) {
        UIViewController *indexItem = [_dataSource pagerViewLayout:self itemForIndex:idx prefetching:NO];
        if (indexItem) {
            items[@(idx)] = indexItem;
        }
    }
    if (items.count > 0) {
        _allItems = [items copy];
    }
}

#pragma mark - caculate index

- (void)caculateIndexWithOffsetX:(CGFloat)offsetX direction:(TYPagerScrollingDirection)direction{
    if (CGRectIsEmpty(_scrollView.frame)) {
        return;
    }
    if (_countOfPagerItems <= 0) {
        _curIndex = -1;
        return;
    }
    // scrollView width
    CGFloat width = CGRectGetWidth(_scrollView.frame);
    NSInteger index = 0;
    // when scroll to progress(changeIndexWhenScrollProgress) will change index
    double percentChangeIndex = _changeIndexWhenScrollProgress;
    if (_changeIndexWhenScrollProgress >= 1.0 || [self progressCaculateEnable]) {
        percentChangeIndex = 0.999999999;
    }
    
    // caculate cur index
    if (direction == TYPagerScrollingLeft) {
        index = ceil(offsetX/width-percentChangeIndex);
    }else {
        index = floor(offsetX/width+percentChangeIndex);
    }
    
    if (index < 0) {
        index = 0;
    }else if (index >= _countOfPagerItems) {
        index = _countOfPagerItems-1;
    }
    if (index == _curIndex) {
        // if index not same,change index
        return;
    }
    
    CGFloat fullScrollContentOffset = width * (_countOfPagerItems - 1);
    if(offsetX == 0){
        index = _countOfPagerItems - 2;
        _curIndex = index;
        if (_delegateFlags.transitionFromIndexToIndex /*&& ![self progressCaculateEnable]*/) {
            [_delegate pagerViewLayout:self transitionFromIndex:0 toIndex:_curIndex animated:NO];
        }
        [_scrollView setContentOffset:CGPointMake(index * CGRectGetWidth(_scrollView.frame),0) animated:NO];
        return;
    }else if (offsetX == fullScrollContentOffset){
        index = 1;
        _curIndex = index;
        if (_delegateFlags.transitionFromIndexToIndex /*&& ![self progressCaculateEnable]*/) {
            [_delegate pagerViewLayout:self transitionFromIndex:_countOfPagerItems-2 toIndex:_curIndex animated:NO];
        }
        [_scrollView setContentOffset:CGPointMake(index * CGRectGetWidth(_scrollView.frame),0) animated:NO];
    }
    else{
        NSInteger fromIndex = MAX(_curIndex, 0);
        _curIndex = index;
        if (_delegateFlags.transitionFromIndexToIndex /*&& ![self progressCaculateEnable]*/) {
            [_delegate pagerViewLayout:self transitionFromIndex:fromIndex toIndex:_curIndex animated:_scrollAnimated];
        }
    }
     _scrollAnimated = YES;
}

- (void)caculateIndexByProgressWithOffsetX:(CGFloat)offsetX direction:(TYPagerScrollingDirection)direction{
    if (CGRectIsEmpty(_scrollView.frame)) {
        return;
    }
    if (_countOfPagerItems <= 0) {
        _curIndex = -1;
        return;
    }
    CGFloat width = CGRectGetWidth(_scrollView.frame);
    CGFloat floadIndex = offsetX/width;
    NSInteger floorIndex = floor(floadIndex);
    if (floorIndex < 0 || floorIndex >= _countOfPagerItems || floadIndex > _countOfPagerItems-1) {
        return;
    }
    
    CGFloat progress = offsetX/width-floorIndex;
    NSInteger fromIndex = 0, toIndex = 0;
    if (direction == TYPagerScrollingLeft) {
        fromIndex = floorIndex;
        toIndex = MIN(_countOfPagerItems -1, fromIndex + 1);
        if (fromIndex == toIndex && toIndex == _countOfPagerItems-1) {
            fromIndex = _countOfPagerItems-2;
            progress = 1.0;
        }
    }else {
        toIndex = floorIndex;
        fromIndex = MIN(_countOfPagerItems-1, toIndex +1);
        progress = 1.0 - progress;
    }
    
    if (_delegateFlags.transitionFromIndexToIndexProgress) {
        [_delegate pagerViewLayout:self transitionFromIndex:fromIndex toIndex:toIndex progress:progress];
    }
}

- (BOOL)progressCaculateEnable {
    return _delegateFlags.transitionFromIndexToIndexProgress && _progressAnimateEnabel && !_isTapScrollMoved;
}

#pragma mark - UIScrollViewDelegate

- (NSInteger) pageIndexByAdding:(NSInteger) offset from:(NSInteger) index {
    // Complicated stuff with negative modulo
    while (offset<0) offset += _countOfPagerItems;
    return (_countOfPagerItems+index+offset) % _countOfPagerItems;
    
}
- (UIViewController *) loadControllerAtIndex:(NSInteger) index andPlaceAtIndex:(NSInteger) destIndex {
    if (_scrollView.subviews.count > 3){
        for(id child in [_scrollView subviews]){
            [child removeFromSuperview];
        }
    }
    NSNumber *idx = @(index);
    UIViewController *viewController = [_allItems objectForKey:idx];
    viewController.view.tag = 0;
    
    CGRect viewFrame = CGRectMake(0, 0, _scrollView.frame.size.width, _scrollView.frame.size.height);
    int offset = 2;
    viewFrame = CGRectOffset(viewFrame, _scrollView.frame.size.width * (destIndex + offset), 0);
    viewController.view.frame = viewFrame;
    
    [_scrollView addSubview:viewController.view];
    return viewController;
}
- (void) removeControllerInScrollView {
    if (_scrollView.subviews.count > 0){
        for(id child in [_scrollView subviews]){
            [child removeFromSuperview];
        }
    }
}
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if(_countOfPagerItems>0){
        if (!scrollView.superview) {
            return;
        }
        // get scrolling direction
        CGFloat offsetX = scrollView.contentOffset.x;
        TYPagerScrollingDirection direction = offsetX >= _preOffsetX ? TYPagerScrollingLeft : TYPagerScrollingRight;
        
        CGFloat size = _scrollView.frame.size.width;

        _scrollView.bounces = YES;
        
        NSInteger newPageIndex = _curIndex;
        
        if (offsetX <= size)
            newPageIndex = [self pageIndexByAdding:-1 from:_curIndex];
        else if (offsetX >= (size*3)){
            if(offsetX == (size * 3)){
                newPageIndex = [self pageIndexByAdding:+1 from:_curIndex];
            }else{
                CGFloat selectedIndex = offsetX/size;
                newPageIndex = [self pageIndexByAdding: selectedIndex - 1 from:0];
            }
        }

        // layout items
        [self layoutIfNeed:newPageIndex];
        _isTapScrollMoved = NO;
        
        // caculate index and progress
//        if ([self progressCaculateEnable]) {
//            [self caculateIndexByProgressWithOffsetX:offsetX direction:direction];
//        }
//        [self caculateIndexWithOffsetX:offsetX direction:direction];
        
        if (_delegateFlags.pagerViewLayoutDidScroll) {
            [_delegate pagerViewLayoutDidScroll:self];
        }
    }
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView
{
    _preOffsetX = scrollView.contentOffset.x;
    if ([_delegate respondsToSelector:@selector(pagerViewLayoutWillBeginDragging:)]) {
        [_delegate pagerViewLayoutWillBeginDragging:self];
    }
}

- (void)scrollViewWillScrollToView:(UIScrollView *)scrollView animate:(BOOL)animate {
    _preOffsetX = scrollView.contentOffset.x;
    _isTapScrollMoved = YES;
    _scrollAnimated = animate;
    if ([_delegate respondsToSelector:@selector(pagerViewLayoutWillBeginScrollToView:animate:)]) {
        [_delegate pagerViewLayoutWillBeginScrollToView:self animate:animate];
    }
}

- (void)scrollViewDidScrollToView:(UIScrollView *)scrollView animate:(BOOL)animate {
    if ([_delegate respondsToSelector:@selector(pagerViewLayoutDidEndScrollToView:animate:)]) {
        [_delegate pagerViewLayoutDidEndScrollToView:self animate:animate];
    }
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if ([_delegate respondsToSelector:@selector(pagerViewLayoutDidEndDragging:willDecelerate:)]) {
        [_delegate pagerViewLayoutDidEndDragging:self willDecelerate:decelerate];
    }
}

- (void)scrollViewWillBeginDecelerating:(UIScrollView *)scrollView {
    if ([_delegate respondsToSelector:@selector(pagerViewLayoutWillBeginDecelerating:)]) {
        [_delegate pagerViewLayoutWillBeginDecelerating:self];
    }
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    if ([_delegate respondsToSelector:@selector(pagerViewLayoutDidEndDecelerating:)]) {
        [_delegate pagerViewLayoutDidEndDecelerating:self];
    }
}

- (void)scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView {
    if ([_delegate respondsToSelector:@selector(pagerViewLayoutDidEndScrollingAnimation:)]) {
        [_delegate pagerViewLayoutDidEndScrollingAnimation:self];
    }
}

#pragma mark - Observer

- (void)dealloc {
    _scrollView.delegate = nil;
    _scrollView = nil;
    if (_reuseIdentifyItems) {
        [_reuseIdentifyItems removeAllObjects];
    }
    if (_reuseIdentifyClassOrNib) {
        [_reuseIdentifyClassOrNib removeAllObjects];
    }
}

@end
