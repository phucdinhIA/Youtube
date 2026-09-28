#import "Headers.h"
#import <os/log.h>

%hook YTInnerTubeCollectionViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    static NSUInteger logged = 0;
    if (logged++ >= 8) return;
    NSMutableArray<UIView *> *views = [NSMutableArray arrayWithObject:self.view];
    while (views.count) {
        UIView *view = views.lastObject;
        [views removeLastObject];
        Class collectionClass = NSClassFromString(@"ASCollectionView");
        if (collectionClass && [view isKindOfClass:collectionClass]) {
            UICollectionView *collection = (UICollectionView *)view;
            NSMutableArray<NSString *> *frames = [NSMutableArray array];
            for (UICollectionViewCell *cell in collection.visibleCells) {
                if (frames.count >= 6) break;
                [frames addObject:[NSString stringWithFormat:@"%.0f:%.0f", cell.frame.origin.x, cell.frame.size.width]];
            }
            NSString *visible = [frames componentsJoinedByString:@","];
            os_log(OS_LOG_DEFAULT, "[TransDuckFeed] controller=%{public}s width=%.0f sizeClass=%ld layout=%{public}s sections=%ld visible=%{public}s", NSStringFromClass(self.class).UTF8String, collection.bounds.size.width, (long)collection.traitCollection.horizontalSizeClass, NSStringFromClass(collection.collectionViewLayout.class).UTF8String, (long)[collection numberOfSections], visible.UTF8String);
            if ([self isKindOfClass:NSClassFromString(@"YTAppCollectionViewController")] && [collection numberOfSections] > 5) {
                NSMutableArray<NSString *> *sections = [NSMutableArray array];
                for (NSInteger section = 0; section < MIN(20, [collection numberOfSections]); section++) {
                    NSInteger count = [collection numberOfItemsInSection:section];
                    UICollectionViewLayoutAttributes *item = count ? [collection.collectionViewLayout layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:section]] : nil;
                    CGRect frame = item.frame;
                    [sections addObject:[NSString stringWithFormat:@"%ld/%ld=%.0f,%.0f,%.0f,%.0f", (long)section, (long)count, frame.origin.x, frame.origin.y, frame.size.width, frame.size.height]];
                }
                NSString *summary = [sections componentsJoinedByString:@";"];
                os_log(OS_LOG_DEFAULT, "[TransDuckFeedSections] %{public}s", summary.UTF8String);
            }
        }
        [views addObjectsFromArray:view.subviews];
    }
}
%end

// Hide Subbar
%hook YTHeaderContentComboView
- (void)enableSubheaderBarWithView:(id)arg1 { if (!IS_ENABLED(HideSubbar)) %orig; }
- (void)setFeedHeaderScrollMode:(int)arg1 { 
    int temp = IS_ENABLED(HideSubbar) ? 0 : arg1;
    %orig(temp);
}
- (id)initWithChildView:(id)arg1 headerView:(id)arg2 {
    self = %orig;
    if (self && IS_ENABLED(HideSubbar)) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(setNeedsLayout) name:@"YouModReloadHeaderBar" object:nil];
    }
    return self;
}
%end

// Hide voice search button
%hook YTSearchViewController
- (void)viewDidLoad {
    %orig;
    if (IS_ENABLED(HideVoiceSearch)) {
        [self setValue:@(NO) forKey:@"_isVoiceSearchAllowed"];
    }
}
- (void)setSuggestions:(id)arg1 { if (!IS_ENABLED(HideSearchHis)) %orig; }
%end

// Hide search history and suggestions
%hook YTPersonalizedSuggestionsCacheProvider
- (id)activeCache { return IS_ENABLED(HideSearchHis) ? nil : %orig; }
%end

// Hide related videos in the player
%hook YTWatchNextResultsViewController
- (void)setVisibleSections:(NSInteger)sections {
    if (![self.parentViewController isKindOfClass:%c(YTWatchNextResponseViewController)]) {
        %orig;
        return;
    }
    NSInteger value = IS_ENABLED(HideRelatedVideos) ? 1 : sections;
    %orig(value);
}
%end

static void YouModFilterChannelButtons(_ASDisplayView *self, NSString *iden) {
    UIView *sup = self.superview;
    if ([sup isKindOfClass:%c(ASScrollView)]) {
        ASScrollView *scroll = (ASScrollView *)sup;
        ASDisplayNode *node = scroll.scrollNode;
        for (_ASDisplayView *view in node.yogaChildren) {
            if ([[view description] containsString:iden]) {
                [node removeYogaChild:view];
                [self removeFromSuperview];
                break;
            }
        }
    } else {
        UIViewController *con = self._viewControllerForAncestor;
        if ([con isKindOfClass:%c(YTPageHeaderViewController)]) {
            _ASDisplayView *dpv = (_ASDisplayView *)sup;
            ASDisplayNode *node = dpv.keepalive_node;
            _ASDisplayView *maindpv = (_ASDisplayView *)dpv.superview;
            ASDisplayNode *mainNode = maindpv.keepalive_node;
            [mainNode removeYogaChild:node];
            [dpv removeFromSuperview];
        } else if ([con isKindOfClass:%c(YTWatchNextResultsViewController)]) {
            _ASDisplayView *dpv = (_ASDisplayView *)sup;
            ASDisplayNode *node = dpv.keepalive_node;
            for (id child in [node.yogaChildren copy]) {
                if ([[child description] containsString:iden]) {
                    [node removeYogaChild:child];
                    [self removeFromSuperview];
                    break;
                }
            }
        }
    }
}

%hook _ASDisplayView
- (void)didMoveToWindow {
    %orig;
    NSString *iden = self.accessibilityIdentifier;
    if (!iden || iden.length == 0) return;
    BOOL remove = NO;
    if ([iden isEqualToString:@"eml.header_community_button"] && IS_ENABLED(RemoveChannelCommunityButton)) {
        remove = YES;
    } else if ([iden isEqualToString:@"id.sponsor_button"] && IS_ENABLED(RemoveChannelSponsorAll)) {
        remove = YES;
    }
    if (remove) {
        YouModFilterChannelButtons(self, iden);
    }
}
%end
