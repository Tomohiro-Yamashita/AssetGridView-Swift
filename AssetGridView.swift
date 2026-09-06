//
//  AssetGridView.swift
//
//  A self-contained photo thumbnail grid built directly on the Photos framework.
//
//  Features
//  --------
//  * Displays PHAssets as a scrollable thumbnail grid (custom touch-driven
//    scrolling with inertia and rubber-band bouncing -- no UIScrollView).
//  * Pinch in / out to change the number of columns. The grid re-aligns to a
//    whole number of columns when the gesture ends, animating every thumbnail
//    from its old position to its new one.
//  * Ring-buffer cell pool: a fixed pool of cells (default 800) is recycled
//    around the current "origin" asset, so memory stays bounded regardless of
//    library size.
//  * Multi-resolution textures per cell (small / medium / large) requested
//    through PHCachingImageManager and released when cells scroll far away
//    or the zoom level no longer needs them.
//
//  Usage
//  -----
//      let grid = AssetGridView(frame: view.bounds)
//      grid.autoresizingMask = [.flexibleWidth, .flexibleHeight]
//      grid.delegate = self
//      view.addSubview(grid)
//
//      let options = PHFetchOptions()
//      options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
//      grid.setAssets(PHAsset.fetchAssets(with: .image, options: options))
//
//  The view does not request photo library authorization itself; do that
//  before calling `setAssets`. It also does not observe library changes --
//  call `setAssets` again from your `PHPhotoLibraryChangeObserver` if needed
//  (cells for assets that survive the change keep their loaded thumbnails
//  and animate to their new positions).
//
//  Everything except `AssetGridView` and `AssetGridViewDelegate` is private
//  to this file, so it can be dropped into any project without collisions.
//

import UIKit
import Photos

// MARK: - Delegate

public protocol AssetGridViewDelegate: AnyObject {
    /// The user tapped a thumbnail.
    func assetGridView(_ gridView: AssetGridView, didSelect asset: PHAsset)

    /// The "focused" asset changed. The focused asset is the layout origin:
    /// the cell nearest to the last touch / pinch center / scroll anchor.
    /// Optional -- a default empty implementation is provided.
    func assetGridView(_ gridView: AssetGridView, didChangeFocus asset: PHAsset?)
}

public extension AssetGridViewDelegate {
    func assetGridView(_ gridView: AssetGridView, didChangeFocus asset: PHAsset?) {}
}

// MARK: - AssetGridView

open class AssetGridView: UIView {

    // MARK: Public configuration

    public weak var delegate: AssetGridViewDelegate?

    /// Number of columns when the view first appears.
    public var initialColumnCount: Int = 4

    /// The smallest number of columns the user can pinch out to.
    public var minimumColumnCount: Int = 1

    /// The largest number of thumbnails allowed across the short edge of the
    /// view (i.e. how far the user can pinch in). `nil` picks a device
    /// default (13 on iPhone, 25 on iPad).
    public var maximumThumbnailsAcrossShortEdge: Int?

    /// Each thumbnail is drawn at this fraction of its grid slot,
    /// producing the gap between thumbnails.
    public var cellContentScale: CGFloat = 0.97

    /// Margin between the view's bounds and the grid content.
    public var contentMargin: CGFloat = 5

    /// Extra scrollable space below the last row.
    public var bottomInset: CGFloat = 0

    /// Allow PHImageManager to download images from iCloud when a local
    /// thumbnail is not available.
    public var allowsNetworkAccess: Bool = true

    /// The asset currently acting as the layout origin (read-only).
    public private(set) var focusedAsset: PHAsset?

    /// Number of assets currently displayed.
    public var assetCount: Int { return source.count }

    // MARK: Public API

    /// Display the contents of a fetch result.
    public func setAssets(_ fetchResult: PHFetchResult<PHAsset>) {
        setSource(.fetchResult(fetchResult))
    }

    /// Display an explicit array of assets.
    public func setAssets(_ assets: [PHAsset]) {
        setSource(.array(assets))
    }

    /// Remove all assets.
    public func clearAssets() {
        setSource(.empty)
    }

    /// The asset whose thumbnail contains `point` (in the view's coordinate
    /// space), if any.
    public func asset(at point: CGPoint) -> PHAsset? {
        guard source.count > 0 else { return nil }
        let result = indexWithPoint(point, originRect: animatedOriginRect(), frame: bounds,
                                    originIndex: originIndex, originPosition: originPosition, rowEnds: rowEnds)
        guard result.outside == false else { return nil }
        return source.asset(at: result.index)
    }

    /// Scroll so that `asset` is vertically centered, if it is present.
    public func scrollTo(asset: PHAsset, animated: Bool = true) {
        guard let index = source.index(of: asset) else { return }
        stopScroll()
        changeOriginIndex(index, forceUpdate: true)

        let targetY = contentFrame.midY - originRect.size.height / 2
        if animated {
            if animatePoint < 1 {
                setEveryAnimPointsToStartPoints()
            } else {
                previousOriginRect = originRect
            }
            originRect.origin.y = targetY
            let over = scrollIsOver(0)
            if over.over {
                originRect = over.newOriginRect
            }
            bounceDestinationOriginRect = originRect
            animateDuration = 0.3
            startAnimation()
        } else {
            originRect.origin.y = targetY
            let over = scrollIsOver(0)
            if over.over {
                originRect = over.newOriginRect
            }
            previousOriginRect = originRect
            updateThumbnail()
            updateCellImages()
        }
    }

    // MARK: Private state

    private var source: AssetSource = .empty
    private var needsSourceApply = false
    private var lastLayoutSize = CGSize.zero

    private let cachingManager = PHCachingImageManager()

    private var currentCells = CellManager()
    private var previousCells = CellManager()

    private let deviceIsPad = UIDevice.current.userInterfaceIdiom == .pad
    private let cellProportion: CGFloat = 1 // slot height / width

    // Origin: the anchor cell everything else is laid out relative to.
    private var contentFrame = CGRect.zero
    private var thumbnailSizeMin: CGFloat = 0
    private var originRect = CGRect.zero
    private var previousOriginRect = CGRect.zero
    private var originPosition = CellPosition()
    private var originIndex: Int = 0
    private var lastModifiedOriginRect = CGRect.zero

    // Layout-change animation.
    private var layoutTimer: Timer?
    private var animateStartTime: CFTimeInterval = 0
    private var animateDuration: Double = 0.3
    private var animatePoint: Float = 1.0 // < 1 means a layout animation is running
    private var rowEndsForAnimate = PositionEnds()
    private var rowEnds = PositionEnds()
    private var previousRowEnds = PositionEnds()

    // Scrolling.
    private var scrollTimer: Timer?
    private var releasedTime: Double = 0
    private var releasedSpeed: Double = 0
    private var singleTouchHistory = [TouchStamp]()
    private var scrolling = false
    private var scrollStartPoint = CGPoint.zero
    private var scrollStartOriginRect = CGRect.zero
    private var scrollingSpeed: Double = 0
    private var bounceStartTime = Date()
    private var bounceDestinationOriginRect = CGRect.zero
    private var scrollBouncing = false
    private var afterScroll = false

    // Pinch.
    private var pinchDoing = false
    private var pinchStartDistance: CGFloat = 0
    private var pinchStartRect = CGRect.zero
    private var pinchCenterInRect = CGPoint.zero
    private var thumbnailSizeLevel: Int = 0

    // Touches (raw touch handling -- no gesture recognizers, matching the
    // original scrolling / pinching feel).
    private var activeTouches = [UITouch]()

    // Coalesced redraw after thumbnails finish loading.
    private var refreshTimer: Timer?

    // MARK: Init / deinit

    public override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isMultipleTouchEnabled = true
        isUserInteractionEnabled = true
        currentCells.cachingManager = cachingManager
        previousCells.cachingManager = cachingManager
        resetContentFrame()
        resetOrigin()
    }

    deinit {
        layoutTimer?.invalidate()
        scrollTimer?.invalidate()
        refreshTimer?.invalidate()
        cachingManager.stopCachingImagesForAllAssets()
    }

    // MARK: Layout lifecycle

    open override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastLayoutSize else { return }
        let firstLayout = (lastLayoutSize == .zero)
        lastLayoutSize = bounds.size
        resetContentFrame()
        if firstLayout {
            resetOrigin()
        }
        if needsSourceApply {
            needsSourceApply = false
            applySource()
        } else if firstLayout == false && source.count > 0 {
            frameSizeDidChange()
        }
    }

    private func resetContentFrame() {
        contentFrame = bounds.insetBy(dx: contentMargin, dy: contentMargin)
    }

    private func resetOrigin() {
        let maxAcross = maximumThumbnailsAcrossShortEdge ?? (deviceIsPad ? 25 : 13)
        let shortEdge = min(contentFrame.size.width, contentFrame.size.height)
        thumbnailSizeMin = max(shortEdge, 0) / CGFloat(max(maxAcross, 1))

        let columns = max(initialColumnCount, 1)
        let thumbSize = contentFrame.size.width / CGFloat(columns)

        // The origin starts as the bottom-right cell, just below the visible
        // area; `scrollIsOver` pulls the grid up so the last row sits at the
        // bottom edge (like the system Photos app opened at the newest photo).
        originRect = CGRect(x: contentFrame.origin.x + contentFrame.size.width - thumbSize,
                            y: contentFrame.origin.y + contentFrame.size.height,
                            width: thumbSize,
                            height: thumbSize * cellProportion)
        originPosition = CellPosition()
        originIndex = 0

        rowEnds.rightEnd = 0
        rowEnds.leftEnd = -Float(columns) + 1
        rowEndsForAnimate = rowEnds
        previousRowEnds = rowEnds
        previousOriginRect = originRect
        lastModifiedOriginRect = originRect

        thumbnailSizeLevel = maxLevelWithOriginRect()
    }

    /// Port of the original `viewFrameUpdated` (rotation / resize handling).
    private func frameSizeDidChange() {
        if pinchDoing == false {
            currentCells.setAlpha(1)
        }
        let over = scrollIsOver(0)
        if over.over {
            scrollTimer?.invalidate()
            bounceStartTime = Date()
            scrollStartOriginRect = originRect
            bounceDestinationOriginRect = over.newOriginRect
            scheduleScrollTimer(interval: 0.01) { [weak self] timer in
                self?.bounceAnimation(timer)
            }
        }

        guard source.count > 0 else { return }

        let index = indexWithPoint(CGPoint(x: contentFrame.midX, y: contentFrame.midY),
                                   originRect: originRect, frame: contentFrame,
                                   originIndex: originIndex, originPosition: originPosition,
                                   rowEnds: rowEnds).index
        changeOriginIndex(index, forceUpdate: false)

        // Restore the thumbnail size the user last chose (pinch level),
        // then re-align columns to the new width.
        let rectKeep = originRect
        originRect = resizeRect(originRect, toSize: lastModifiedOriginRect.size)
        previousOriginRect = resizeRect(previousOriginRect, toSize: lastModifiedOriginRect.size)
        updateCellPositions()
        previousOriginRect = rectKeep
    }

    // MARK: Setting assets

    private func setSource(_ newSource: AssetSource) {
        source = newSource
        if bounds.size.width <= 0 || bounds.size.height <= 0 {
            // View not laid out yet -- apply once we have a size.
            needsSourceApply = true
            setNeedsLayout()
            return
        }
        applySource()
    }

    /// Port of the original `transitionFetchResult`: cells whose assets exist
    /// in both the old and the new set keep their loaded thumbnails and
    /// animate to their new positions; new cells fade in, removed ones fade out.
    private func applySource() {
        stopScroll()

        if source.count == 0 {
            previousCells.migrate(fromAnotherManager: currentCells, previous: true)
            for cell in previousCells.cellsArray {
                cell.alpha = 0
            }
            setFocusedAsset(nil)
            animateDuration = 0.3
            startAnimation()
            return
        }

        // Keep the focused asset if it survives, otherwise focus the newest one.
        var newOriginIndex = source.count - 1
        if let asset = focusedAsset, let index = source.index(of: asset) {
            newOriginIndex = index
        }
        originIndex = newOriginIndex
        setFocusedAsset(source.asset(at: newOriginIndex))

        previousCells.migrate(fromAnotherManager: currentCells, previous: true)
        currentCells.setNewSource(source, originIndex: originIndex,
                                  originPosition: originPosition, positionEnds: rowEnds)

        for cell in currentCells.cellsArray {
            cell.previousAlpha = 0 // new cells fade in
        }

        requestThumbnailImagesWithRange(100, levelNum: 0)

        // Move already-loaded textures from old cells to their new cells.
        for previousCell in previousCells.cellsArray {
            guard let asset = previousCell.asset else { continue }
            if let newCell = currentCells.cellWithAsset(asset) {
                let position = newCell.position
                let index = newCell.index
                newCell.migrate(from: previousCell)
                if let migratedAsset = newCell.asset {
                    currentCells.cellsDictionary[migratedAsset] = newCell
                    previousCells.cellsDictionary.removeValue(forKey: migratedAsset)
                }
                newCell.index = index
                newCell.position = position
            } else {
                previousCell.alpha = 0 // removed cells fade out
            }
        }

        // If the current row layout no longer spans the content frame,
        // re-align; otherwise just make sure we are not over-scrolled.
        let left = originRect.origin.x + originRect.size.width * CGFloat(rowEnds.leftEnd - originPosition.row)
        let right = originRect.origin.x + originRect.size.width * CGFloat(rowEnds.rightEnd - originPosition.row + 1)
        if abs(contentFrame.minX - left) > 0.5 || abs(contentFrame.maxX - right) > 0.5 {
            updateCellPositions()
        } else {
            previousOriginRect = originRect
            let over = scrollIsOver(0)
            if over.over {
                originRect = over.newOriginRect
            }
        }

        if deviceIsPad {
            animateDuration = Double(bounds.size.width / originRect.size.width) * 0.02 + 0.5
        } else {
            animateDuration = Double(bounds.size.width / originRect.size.width) * 0.013 + 0.48
        }
        startAnimation()
        updateThumbnail()
    }

    private func setFocusedAsset(_ asset: PHAsset?) {
        guard focusedAsset !== asset else { return }
        focusedAsset = asset
        delegate?.assetGridView(self, didChangeFocus: asset)
    }

    // MARK: Origin handling

    /// Re-anchor the layout on a new origin index. The ring buffer of cells
    /// rotates so that the pool always surrounds the origin.
    private func changeOriginIndex(_ index: Int, forceUpdate: Bool) {
        guard source.count > 0 else { return }
        guard originIndex != index || forceUpdate else { return }

        var resultIndex = index
        if resultIndex < 0 {
            resultIndex = 0
        } else if resultIndex >= source.count {
            resultIndex = source.count - 1
        }

        currentCells.moveOrigin(source, newOrigin: resultIndex,
                                originPosition: originPosition, positionEnds: rowEnds)

        guard let cell = currentCells.originCell() else { return }

        // Keep the relative offsets of the animation / scroll anchor rects.
        let originRectDelta = originDelta(from: originRect, to: previousOriginRect)
        let scrollRectDelta = originDelta(from: originRect, to: scrollStartOriginRect)

        originRect = cell.rect(originRect, originPosition: originPosition)
        previousOriginRect = originRect.offsetBy(dx: originRectDelta.x, dy: originRectDelta.y)
        originPosition = cell.position
        scrollStartOriginRect = originRect.offsetBy(dx: scrollRectDelta.x, dy: scrollRectDelta.y)

        setFocusedAsset(cell.asset)
        originIndex = resultIndex

        updateCellImages()
    }

    // MARK: Cell positions / column alignment

    /// Recompute every cell's grid position after the origin rect changed
    /// (pinch end, rotation, programmatic scroll) and animate to it.
    private func updateCellPositions() {
        if animatePoint < 1 {
            setEveryAnimPointsToStartPoints()
        } else {
            previousOriginRect = originRect
        }

        let align = alignRectToFrame(rect: originRect, frame: contentFrame,
                                     addition: 0, originPosition: originPosition)
        originRect = align.rect
        previousRowEnds = rowEnds
        rowEnds = align.rowEnds
        let count = align.count

        if deviceIsPad {
            animateDuration = (Double(count) / 10) * 0.1 + 0.25
        } else {
            animateDuration = (Double(count) / 10) * 0.2 + 0.25
        }

        for cell in currentCells.cellsArray {
            cell.position = positionWithIndex(index: cell.index, originIndex: originIndex,
                                              originPosition: originPosition, positionEnds: rowEnds)
        }

        rowEndsForAnimate = align.rowEndsBeforeAlign ?? rowEnds

        let over = scrollIsOver(0)
        if over.over {
            originRect = over.newOriginRect
        }
        bounceDestinationOriginRect = originRect
        startAnimation()
    }

    private func alignedThumbnailCount(rect originRect: CGRect, frame frameRect: CGRect) -> Int {
        let result = Int(0.5 + (frameRect.size.width / originRect.size.width))
        return result > 0 ? result : 1
    }

    /// Snap the free-form origin rect (as it is during a pinch) to a whole
    /// number of columns filling the content frame.
    private func alignRectToFrame(rect originRect: CGRect, frame frameRect: CGRect,
                                  addition additionCount: Int, originPosition: CellPosition)
        -> (rect: CGRect, rowEnds: PositionEnds, count: Int, rowEndsBeforeAlign: PositionEnds?) {

        let minCount = max(minimumColumnCount, 1)

        var count = alignedThumbnailCount(rect: originRect, frame: frameRect) + additionCount
        if count < minCount {
            count = minCount
        }

        var newRectWidth = frameRect.size.width / CGFloat(count)
        var positionEndsBeforeAlign: PositionEnds? = nil

        // Pinched in beyond the minimum thumbnail size: clamp the column
        // count, remembering the unclamped row layout so the snap animates
        // from where the fingers actually were.
        if newRectWidth < thumbnailSizeMin && thumbnailSizeMin > 0 {
            let alignNumberBeforeLimited = Int((originRect.origin.x - frameRect.origin.x) / originRect.size.width + 0.5)
            positionEndsBeforeAlign = PositionEnds(
                leftEnd: originPosition.row - Float(alignNumberBeforeLimited),
                rightEnd: originPosition.row + Float(count - alignNumberBeforeLimited - 1))

            let limitedCount = max(Int(frameRect.size.width / thumbnailSizeMin), minCount)
            newRectWidth = frameRect.size.width / CGFloat(limitedCount)
            count = limitedCount
        }

        let sizeChange = newRectWidth / originRect.size.width
        var resultRect = rectMovedInsideHorizontally(resizeRect(originRect, scale: sizeChange), frame: frameRect)
        let alignNumber = Int((resultRect.origin.x - frameRect.origin.x) / newRectWidth + 0.5)
        resultRect.origin.x = frameRect.origin.x + (CGFloat(alignNumber) * newRectWidth)

        let positionEnds = PositionEnds(leftEnd: originPosition.row - Float(alignNumber),
                                        rightEnd: originPosition.row + Float(count - alignNumber - 1))

        resultRect.size.width = newRectWidth
        resultRect.size.height = resultRect.size.width * cellProportion
        return (resultRect, positionEnds, count, positionEndsBeforeAlign)
    }

    // MARK: Hit testing

    /// Which asset index sits under `point`, given the current layout.
    private func indexWithPoint(_ point: CGPoint, originRect rect: CGRect, frame frameRect: CGRect,
                                originIndex: Int, originPosition: CellPosition,
                                rowEnds: PositionEnds) -> (index: Int, outside: Bool) {

        guard rect.size.width > 0 && rect.size.height > 0 else { return (originIndex, true) }

        var relativePoint = point
        relativePoint.x -= rect.origin.x
        relativePoint.y -= rect.origin.y

        var row = Int(relativePoint.x / rect.size.width)
        if relativePoint.x < 0 {
            row -= 1
        }
        var column = Int(relativePoint.y / rect.size.height)
        if relativePoint.y < 0 {
            column -= 1
        }

        let relativeEnds = relativePositionEnds(rowEnds, originPosition: originPosition)
        let width = Int(rowEnds.rightEnd - rowEnds.leftEnd + 1)

        var result = originIndex
        var outside = false
        if column == 0 {
            result = originIndex + row
        } else if column > 0 {
            result = originIndex + ((column - 1) * width) + Int(relativeEnds.rightEnd) + row - Int(relativeEnds.leftEnd) + 1
        } else {
            result = originIndex + ((column + 1) * width) + Int(relativeEnds.leftEnd) + row - Int(relativeEnds.rightEnd) - 1
        }
        if result < 0 {
            result = 0
            outside = true
        } else if result >= source.count {
            result = source.count - 1
            outside = true
        }
        return (result, outside)
    }

    // MARK: Over-scroll detection

    /// While inertia-scrolling: has the origin cell left the visible area,
    /// and which cell should become the new origin?
    private func originIsOver(_ speed: Double) -> (over: CGFloat, newOriginIndex: Int) {
        var newOriginIndex = originIndex
        var over: CGFloat = 0
        guard source.count > 0 else { return (over, newOriginIndex) }

        let marginWithSpeed = CGFloat(abs(speed) * 0.02)
        var evaluateFrame = contentFrame
        if speed > 0 {
            evaluateFrame.size.height += marginWithSpeed
            evaluateFrame.origin.y -= marginWithSpeed
        } else {
            evaluateFrame.size.height += marginWithSpeed
        }

        var point = CGPoint(x: contentFrame.origin.x + contentFrame.size.width / 2, y: 0)
        if originRect.origin.y + originRect.size.height > evaluateFrame.origin.y + evaluateFrame.size.height {
            over = (originRect.origin.y + originRect.size.height) - (evaluateFrame.origin.y + evaluateFrame.size.height)
            point.y = evaluateFrame.origin.y + originRect.size.height
            newOriginIndex = indexWithPoint(point, originRect: originRect, frame: bounds,
                                            originIndex: originIndex, originPosition: originPosition,
                                            rowEnds: rowEnds).index
        } else if originRect.origin.y < evaluateFrame.origin.y {
            over = evaluateFrame.origin.y - originRect.origin.y
            point.y = evaluateFrame.origin.y + evaluateFrame.size.height - originRect.size.height
            newOriginIndex = indexWithPoint(point, originRect: originRect, frame: bounds,
                                            originIndex: originIndex, originPosition: originPosition,
                                            rowEnds: rowEnds).index
        }
        return (over, newOriginIndex)
    }

    /// Is the grid scrolled past its first / last row, and where should it
    /// bounce back to?
    private func scrollIsOver(_ speed: Double) -> (over: Bool, newOriginRect: CGRect) {
        var newOriginRect = originRect
        var over = false
        guard source.count > 0 else { return (over, newOriginRect) }

        let marginWithSpeed = CGFloat(abs(speed) * 0.02)

        var firstRect = rectWithIndex(0, originRect: originRect, originIndex: originIndex,
                                      originPosition: originPosition, positionEnds: rowEnds)
        var lastRect = rectWithIndex(source.count - 1, originRect: originRect, originIndex: originIndex,
                                     originPosition: originPosition, positionEnds: rowEnds)
        lastRect.origin.y += bottomInset

        if firstRect.origin.y < contentFrame.origin.y
            && lastRect.origin.y + lastRect.size.height < contentFrame.origin.y + contentFrame.size.height - marginWithSpeed {
            newOriginRect.origin.y += contentFrame.origin.y + contentFrame.size.height - lastRect.origin.y - lastRect.size.height
            firstRect = rectWithIndex(0, originRect: newOriginRect, originIndex: originIndex,
                                      originPosition: originPosition, positionEnds: rowEnds)
            over = true
        }
        if firstRect.origin.y > contentFrame.origin.y + marginWithSpeed {
            newOriginRect.origin.y -= firstRect.origin.y - contentFrame.origin.y
            over = true
        }
        return (over, newOriginRect)
    }

    // MARK: Rendering

    private func animatedOriginRect() -> CGRect {
        return intermediateRect(previousOriginRect, endRect: originRect, mergePoint: CGFloat(animatePoint))
    }

    /// Lay out every visible cell for the current animation point.
    /// Called every frame while scrolling or animating.
    private func updateThumbnail() {
        let animatedRect = animatedOriginRect()
        guard animatedRect.size.height > 0 else { return }

        let columnMax = originPosition.column + Int64((bounds.size.height - animatedRect.origin.y) / animatedRect.size.height) + 1
        let columnMin = originPosition.column - Int64(animatedRect.origin.y / animatedRect.size.height) - 1

        func update(_ cell: Cell) {
            let column = cell.animatedPosition(animatePoint, rowEnds: rowEndsForAnimate,
                                               previousRowEnds: previousRowEnds).column
            if column >= columnMin && column < columnMax && cell.isEmpty == false {
                if cell.imageView.superview == nil {
                    addSubview(cell.imageView)
                }
                if cell.imageView.superview === self {
                    let newFrame = cell.contentRect(animatedRect, originPosition: originPosition,
                                                    animatePoint: animatePoint,
                                                    rowEnds: rowEndsForAnimate,
                                                    previousRowEnds: previousRowEnds)
                    cell.imageView.frame = resizeRect(newFrame, scale: cellContentScale)
                }
                cell.setImageViewAlpha(animatePoint)
            } else if cell.imageView.superview === self {
                cell.imageView.removeFromSuperview()
            }
        }

        for cell in previousCells.cellsArray {
            update(cell)
        }
        for cell in currentCells.cellsArray {
            update(cell)
        }
    }

    // MARK: Layout-change animation

    private func startAnimation() {
        layoutTimer?.invalidate()
        animateStartTime = CACurrentMediaTime()
        animatePoint = 0
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
            self?.layoutAnimationTick(timer)
        }
        layoutTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func layoutAnimationTick(_ timer: Timer) {
        let speed: Double = 1.3 * 0.6
        let interval = Float((CACurrentMediaTime() - animateStartTime) / (animateDuration * speed))

        // Double-eased cosine curve (same easing as the original).
        animatePoint = Float(cos(Double(interval - 1) * Double.pi) / 2) + 0.5
        animatePoint = (Float(cos(Double(animatePoint - 1) * Double.pi) / 2) + 0.5 + animatePoint) / 2

        if interval >= 1 {
            timer.invalidate()
            endAnimation()
        }
        updateThumbnail()
    }

    private func endAnimation() {
        layoutTimer?.invalidate()
        animatePoint = 1

        previousCells.clear()
        updateCellImages()

        for cell in currentCells.cellsArray {
            cell.previousPosition = cell.position
        }
        if pinchDoing == false {
            currentCells.setAlpha(1)
        }
    }

    /// If a layout animation is interrupted by a new one, freeze every cell
    /// at its current animated position / alpha so the new animation starts
    /// from where things are on screen instead of jumping.
    private func setEveryAnimPointsToStartPoints() {
        previousOriginRect = animatedOriginRect()

        func setCell(_ cell: Cell) {
            if cell.positionIsNull == false {
                cell.previousPosition = cell.animatedPosition(animatePoint, rowEnds: rowEndsForAnimate,
                                                              previousRowEnds: previousRowEnds)
                cell.previousAlpha = cell.animatedAlpha(animatePoint)
            }
        }
        for cell in previousCells.cellsArray {
            setCell(cell)
        }
        for cell in currentCells.cellsArray {
            setCell(cell)
        }
    }

    // MARK: Thumbnail loading

    /// How large the requested image should be for each texture level.
    private func imageSize(forLevel level: Int) -> CGSize {
        let shortLength = min(bounds.size.width, bounds.size.height)
        switch level {
        case 0:
            return CGSize(width: 30, height: 30)
        case 1:
            return CGSize(width: 200, height: 200)
        case 2:
            return CGSize(width: shortLength * 2, height: shortLength * 2)
        default:
            return CGSize(width: 30, height: 30)
        }
    }

    /// The highest texture level worth loading at the current thumbnail size.
    private func maxLevelWithOriginRect() -> Int {
        let shortLength = min(bounds.size.width, bounds.size.height)
        guard shortLength > 0 else { return 0 }
        if deviceIsPad {
            if originRect.size.width > shortLength * 0.7 {
                return 2
            } else if originRect.size.width > shortLength * 0.18 {
                return 1
            }
        } else {
            if originRect.size.width > shortLength * 0.7 {
                return 2
            } else if originRect.size.width > shortLength * 0.3 {
                return 1
            }
        }
        return 0
    }

    /// Request thumbnails around the origin at the resolution the current
    /// zoom level needs. While fast-scrolling, only tiny thumbnails are
    /// requested.
    private func updateCellImages() {
        guard source.count > 0 else { return }

        var requestCountSmall = 300
        var requestCountMedium = 15
        let requestCountLarge = 1
        if deviceIsPad {
            requestCountSmall = 600
            requestCountMedium = 30
        }

        let speed = abs(scrollingSpeed)
        if thumbnailSizeLevel > 1 && speed <= speedIgnoreUpdateThumbImages() {
            requestThumbnailImagesWithRange(requestCountLarge, levelNum: 2)
        } else if thumbnailSizeLevel > 0 && speed <= speedIgnoreUpdateThumbImages() {
            requestThumbnailImagesWithRange(requestCountMedium, levelNum: 1)
        } else {
            requestThumbnailImagesWithRange(requestCountSmall, levelNum: 0)
        }
    }

    private func speedIgnoreUpdateThumbImages() -> Double {
        return 100
    }

    /// Request `levelNum` textures for cells within `range` of the origin
    /// and release that level (and above) for cells outside it.
    private func requestThumbnailImagesWithRange(_ range: Int, levelNum: Int) {
        var requestArray = [Cell]()
        var releaseArray = [Cell]()
        for cell in currentCells.cellsArray {
            if cell.index >= originIndex - range && cell.index <= originIndex + range {
                requestArray.append(cell)
            } else {
                releaseArray.append(cell)
            }
        }
        // Release first to keep peak memory down.
        for cell in releaseArray {
            cell.removeTexture(fromLevel: levelNum, manager: cachingManager)
        }
        for cell in requestArray {
            requestThumbnailImages(cell, level: levelNum)
        }
    }

    private func requestThumbnailImages(_ cell: Cell?, level: Int) {
        guard let requestCell = cell else { return }
        guard requestCell.requestIDs.isNil(atLevel: level) else { return }
        guard let anAsset = requestCell.asset else { return }

        let requestOptions = PHImageRequestOptions()
        requestOptions.isNetworkAccessAllowed = allowsNetworkAccess
        if level >= 2 {
            requestOptions.deliveryMode = .highQualityFormat
            requestOptions.resizeMode = .exact
        } else {
            requestOptions.deliveryMode = .opportunistic
            requestOptions.resizeMode = .none
        }

        let requestID = cachingManager.requestImage(
            for: anAsset,
            targetSize: imageSize(forLevel: level),
            contentMode: .aspectFit,
            options: requestOptions
        ) { [weak self] result, _ in
            let apply = {
                guard let self = self else { return }
                // The pool cell may have been recycled for another asset
                // while the request was in flight.
                guard requestCell.asset == anAsset else { return }
                guard let image = result else { return }
                self.addTexture(requestCell, image: image, level: level)
                self.scheduleThumbnailRefresh()
            }
            if Thread.isMainThread {
                apply()
            } else {
                DispatchQueue.main.async(execute: apply)
            }
        }
        requestCell.requestIDs.set(requestID, level: level)
    }

    private func addTexture(_ cell: Cell, image: UIImage?, level: Int) {
        guard let image = image else { return }
        cell.texture.set(image, level: level)
        cell.setImage()
    }

    /// Coalesce redraws while many thumbnails arrive in a burst.
    private func scheduleThumbnailRefresh() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.refreshTimer = nil
            self?.updateThumbnail()
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: Scrolling

    private func scheduleScrollTimer(interval: TimeInterval, _ block: @escaping (Timer) -> Void) {
        scrollTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true, block: block)
        scrollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func startScroll() {
        scrolling = true
        scrollStartOriginRect = originRect
    }

    private func updateScroll() {
        let over = scrollIsOver(0)
        originRect.origin.y = scrollStartOriginRect.origin.y + scrollMoved()
        if over.over {
            // Rubber-band resistance when dragging past the ends.
            let overValue = originRect.origin.y - over.newOriginRect.origin.y
            let curvedValue = CGFloat(rubberBand(Double(abs(overValue)), scale: Double(bounds.size.height)))
            originRect.origin.y -= overValue
            if overValue > 0 {
                originRect.origin.y += curvedValue
            } else {
                originRect.origin.y -= curvedValue
            }
        }
        updateThumbnail()
    }

    private func scrollMoved() -> CGFloat {
        guard scrolling, let last = singleTouchHistory.last else { return 0 }
        return last.point.y - scrollStartPoint.y
    }

    private func endScroll() {
        updateCellImages()
    }

    private func stopScroll() {
        scrollTimer?.invalidate()
        scrollBouncing = false
        scrolling = false
        releasedSpeed = 0
        scrollingSpeed = 0
    }

    private func scrollSpeed(from stampA: TouchStamp, to stampB: TouchStamp) -> Double {
        let distance = stampB.point.y - stampA.point.y
        let time = stampB.time - stampA.time
        guard time > 0 else { return 0 }
        return Double(distance) / time
    }

    /// Finger lifted: start inertia scrolling (or bounce back if the grid is
    /// already past its ends).
    private func releaseScroll() {
        updateScroll()

        let historyCount = singleTouchHistory.count - 1
        guard historyCount >= 1 else { return }
        let length = min(3, historyCount)
        releasedSpeed = scrollSpeed(from: singleTouchHistory[historyCount - length],
                                    to: singleTouchHistory[historyCount])

        let over = scrollIsOver(0)
        if over.over {
            scrollingSpeed = releasedSpeed / 2
            bounceStartTime = Date()
            scrollStartOriginRect = originRect
            bounceDestinationOriginRect = over.newOriginRect
            scheduleScrollTimer(interval: 0.001) { [weak self] timer in
                self?.bounceJoiningAnimation(timer)
            }
            return
        }

        if abs(releasedSpeed) < 150 {
            scrollBouncing = false
            return
        }

        // Flicking repeatedly in the same direction accelerates the scroll.
        if (releasedSpeed > 1000 && scrollingSpeed > 0) || (releasedSpeed < -1000 && scrollingSpeed < 0) {
            releasedSpeed += scrollingSpeed
        }

        scrollStartOriginRect = originRect
        releasedTime = singleTouchHistory[historyCount].time
        scheduleScrollTimer(interval: 1.0 / 120.0) { [weak self] timer in
            self?.inertiaAnimation(timer)
        }
    }

    /// Main inertia phase: speed decays hyperbolically.
    private func inertiaAnimation(_ timer: Timer) {
        let currentTime = ProcessInfo.processInfo.systemUptime
        let narrow: Double = 0.45
        let distance = (1 - (narrow / ((currentTime - releasedTime) + narrow))) * releasedSpeed
        let previousSpeed = scrollingSpeed
        scrollingSpeed = (narrow / ((currentTime - releasedTime) + narrow)) * releasedSpeed

        originRect.origin.y = scrollStartOriginRect.origin.y + CGFloat(distance)
        updateThumbnail()

        // Keep the origin cell (and the cell pool around it) inside the view.
        let originOver = originIsOver(0)
        if originOver.over > 0 {
            changeOriginIndex(originOver.newOriginIndex, forceUpdate: false)
        }

        let over = scrollIsOver(scrollingSpeed)
        if over.over {
            bounceStartTime = Date()
            scrollStartOriginRect = originRect
            bounceDestinationOriginRect = over.newOriginRect
            timer.invalidate()
            scheduleScrollTimer(interval: 0.01) { [weak self] t in
                self?.bounceJoiningAnimation(t)
            }
        } else if abs(previousSpeed) >= speedIgnoreUpdateThumbImages()
            && abs(scrollingSpeed) < speedIgnoreUpdateThumbImages() {
            // Slowed down enough to be worth loading real thumbnails.
            updateCellImages()
        } else if abs(scrollingSpeed) < abs(releasedSpeed) * 0.25 {
            // Hand off to the linear tail-off phase.
            releasedTime = currentTime
            releasedSpeed = scrollingSpeed
            scrollStartOriginRect = originRect
            timer.invalidate()
            scheduleScrollTimer(interval: 0.01) { [weak self] t in
                self?.endInertiaAnimation(t)
            }
        }
    }

    /// Final inertia phase: linear deceleration to a stop.
    private func endInertiaAnimation(_ timer: Timer) {
        let currentTime = ProcessInfo.processInfo.systemUptime
        let past = currentTime - releasedTime
        scrollingSpeed = (1 - past * 0.5) * releasedSpeed
        let distance = (scrollingSpeed + releasedSpeed) * past * 0.3

        originRect.origin.y = scrollStartOriginRect.origin.y + CGFloat(distance)
        updateThumbnail()

        let over = scrollIsOver(scrollingSpeed)
        if over.over {
            bounceStartTime = Date()
            scrollStartOriginRect = originRect
            bounceDestinationOriginRect = over.newOriginRect
            timer.invalidate()
            scheduleScrollTimer(interval: 0.01) { [weak self] t in
                self?.bounceJoiningAnimation(t)
            }
        } else if (scrollingSpeed <= 0 && releasedSpeed > 0) || (scrollingSpeed >= 0 && releasedSpeed < 0) || scrollingSpeed == 0 {
            timer.invalidate()
            scrolling = false
            releasedSpeed = 0
            scrollingSpeed = 0
            endScroll()
        }
    }

    /// Overshoot wiggle when hitting an end at speed, before settling.
    private func bounceJoiningAnimation(_ timer: Timer) {
        var interval: Double = 1
        if abs(scrollingSpeed) > 100 {
            let strength = rubberBand(abs(scrollingSpeed), scale: 1000) + 2000
            interval = (-Double(bounceStartTime.timeIntervalSinceNow)) / ((strength + 1500) / 25000)

            let point = sin(interval * Double.pi) * (strength - 2000) / 5000
            let direction: CGFloat = scrollingSpeed < 0 ? -1 : 1
            originRect.origin.y = scrollStartOriginRect.origin.y + (CGFloat(point) * 100 * direction)
            scrollBouncing = true
            updateThumbnail()
        }

        if interval >= 1 {
            bounceStartTime = Date()
            timer.invalidate()
            scheduleScrollTimer(interval: 0.01) { [weak self] t in
                self?.bounceAnimation(t)
            }
        }
    }

    /// Ease back to the resting position after over-scrolling.
    private func bounceAnimation(_ timer: Timer) {
        let interval = (-Double(bounceStartTime.timeIntervalSinceNow)) / 0.8
        let point = 1 - pow(0.001, interval)

        originRect = intermediateRect(scrollStartOriginRect, endRect: bounceDestinationOriginRect,
                                      mergePoint: CGFloat(point))
        scrollBouncing = true
        updateThumbnail()

        if interval >= 1 {
            timer.invalidate()
            scrolling = false
            scrollBouncing = false
            releasedSpeed = 0
            scrollingSpeed = 0
            originRect = bounceDestinationOriginRect
            endScroll()
        }
    }

    // MARK: Pinch

    private func startPinchGesture() {
        guard source.count > 0, activeTouches.count >= 2 else { return }
        pinchDoing = true

        let point1 = activeTouches[0].location(in: self)
        let point2 = activeTouches[1].location(in: self)
        let centerPoint = midPoint(point1, point2)

        // Anchor the zoom on the cell between the fingers.
        let index = indexWithPoint(centerPoint, originRect: animatedOriginRect(), frame: bounds,
                                   originIndex: originIndex, originPosition: originPosition,
                                   rowEnds: rowEnds).index
        changeOriginIndex(index, forceUpdate: true)

        pinchStartRect = originRect
        pinchCenterInRect = pointRatio(centerPoint, in: originRect)
        pinchStartDistance = distanceBetween(point1, point2)

        // Dim everything except the focused cell while pinching.
        currentCells.setAlpha(0.3)
        if let originCell = currentCells.originCell() {
            originCell.alpha = 1
            originCell.previousAlpha = 1
            requestThumbnailImagesWithRange(0, levelNum: 2)
            bringSubviewToFront(originCell.imageView)
        }
        updateThumbnail()
    }

    private func updatePinchGesture() {
        guard activeTouches.count >= 2, pinchStartDistance > 0 else { return }
        let point1 = activeTouches[0].location(in: self)
        let point2 = activeTouches[1].location(in: self)
        let centerPoint = midPoint(point1, point2)
        let distance = distanceBetween(point1, point2)

        var size = distance / pinchStartDistance

        // Soft lower limit (pinching in past the minimum thumbnail size).
        if pinchStartRect.size.width * size < thumbnailSizeMin && pinchStartRect.size.width > 0 {
            let sizeUnit = thumbnailSizeMin / pinchStartRect.size.width
            size = ((pow(size / sizeUnit, 2) / 4) + 0.75) * sizeUnit
        }
        // Soft upper limit (pinching out past a single full-width column).
        let maxWidth = contentFrame.size.width / CGFloat(max(minimumColumnCount, 1))
        if pinchStartRect.size.width * size > maxWidth && pinchStartRect.size.width > 0 {
            let sizeUnit = maxWidth / pinchStartRect.size.width
            let ratio = size / sizeUnit
            size = (1 + (ratio - 1) / (ratio + 1)) * sizeUnit
        }

        originRect = resizeRect(pinchStartRect, scale: size,
                                anchorRatio: pinchCenterInRect, anchorPoint: centerPoint)
        updateThumbnail()
    }

    private func endPinchGesture() {
        pinchDoing = false
        updateCellPositions()
        lastModifiedOriginRect = originRect
        currentCells.setDestinationAlpha(1)
        thumbnailSizeLevel = maxLevelWithOriginRect()
    }

    // MARK: Touch handling

    open override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        afterScroll = (scrollTimer?.isValid == true)

        for aTouch in touches where activeTouches.contains(aTouch) == false {
            activeTouches.append(aTouch)
        }

        guard source.count > 0 else { return }

        if activeTouches.count == 1 {
            scrollTimer?.invalidate()
            singleTouchHistory = []
            scrollingSpeed = 0

            let aTouch = activeTouches[0]
            scrollStartPoint = aTouch.location(in: self)
            singleTouchHistory.append(TouchStamp(touch: aTouch, view: self))

            let index = indexWithPoint(scrollStartPoint, originRect: animatedOriginRect(), frame: bounds,
                                       originIndex: originIndex, originPosition: originPosition,
                                       rowEnds: rowEnds).index
            changeOriginIndex(index, forceUpdate: true)
            startScroll()
        } else if scrolling {
            scrolling = false
            scrollingSpeed = 0
            stopScroll()
            updateCellImages()
        }
    }

    open override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if activeTouches.count == 2 {
            if pinchDoing {
                updatePinchGesture()
            } else {
                startPinchGesture()
            }
        } else if activeTouches.count == 1 && scrolling {
            singleTouchHistory.append(TouchStamp(touch: activeTouches[0], view: self))
            updateScroll()
        }
    }

    open override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if activeTouches.count == 1 && scrolling {
            singleTouchHistory.append(TouchStamp(touch: activeTouches[0], view: self))
            releaseScroll()
        }

        for aTouch in touches {
            activeTouches.removeAll { $0 === aTouch }
        }

        if pinchDoing && activeTouches.count < 2 {
            endPinchGesture()
        }

        if (afterScroll == false || scrollBouncing) && activeTouches.isEmpty {
            evaluateTap()
        }
    }

    open override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for aTouch in touches {
            activeTouches.removeAll { $0 === aTouch }
        }
        scrolling = false
        scrollingSpeed = 0
        if activeTouches.count < 2 && pinchDoing {
            endPinchGesture()
        }
    }

    // MARK: Tap

    private func evaluateTap() {
        guard singleTouchHistory.count >= 2 else { return }
        let firstStamp = singleTouchHistory[0]
        let secondStamp = singleTouchHistory[singleTouchHistory.count - 1]
        let duration = secondStamp.time - firstStamp.time
        let length = distanceBetween(firstStamp.point, secondStamp.point)
        if duration < 0.27 && pinchDoing == false && length < 10 {
            didTap(firstStamp.point)
        }
    }

    private func didTap(_ point: CGPoint) {
        let pointIndex = indexWithPoint(point, originRect: animatedOriginRect(), frame: bounds,
                                        originIndex: originIndex, originPosition: originPosition,
                                        rowEnds: rowEnds)
        guard pointIndex.outside == false else { return }

        changeOriginIndex(pointIndex.index, forceUpdate: true)
        lastModifiedOriginRect = resizeRect(originRect, toSize: lastModifiedOriginRect.size)
        stopScroll()

        if let asset = source.asset(at: pointIndex.index) {
            delegate?.assetGridView(self, didSelect: asset)
        }
    }
}

// MARK: - Asset source

/// Abstracts over the two ways assets can be supplied.
private enum AssetSource {
    case empty
    case fetchResult(PHFetchResult<PHAsset>)
    case array([PHAsset])

    var count: Int {
        switch self {
        case .empty:
            return 0
        case .fetchResult(let result):
            return result.count
        case .array(let assets):
            return assets.count
        }
    }

    func asset(at index: Int) -> PHAsset? {
        guard index >= 0 && index < count else { return nil }
        switch self {
        case .empty:
            return nil
        case .fetchResult(let result):
            return result.object(at: index)
        case .array(let assets):
            return assets[index]
        }
    }

    func index(of asset: PHAsset) -> Int? {
        switch self {
        case .empty:
            return nil
        case .fetchResult(let result):
            let index = result.index(of: asset)
            return index == NSNotFound ? nil : index
        case .array(let assets):
            return assets.firstIndex(of: asset)
        }
    }
}

// MARK: - CellManager (ring buffer of cells)

/// Owns a fixed pool of cells arranged as a ring buffer around the origin
/// index. Moving the origin rotates the array: cells that fall out of range
/// are cleared and refilled with assets entering the range on the other side.
private final class CellManager {
    var cellsArray = [Cell]()
    var cellsDictionary = [PHAsset: Cell]()
    var cachingManager: PHCachingImageManager?
    let cellsCount: Int

    var currentOriginLocal: Int = 0
    var currentOriginGlobal: Int = 0

    init(poolSize: Int = 800) {
        cellsCount = poolSize
        cellsArray.reserveCapacity(poolSize)
        for _ in 0..<poolSize {
            cellsArray.append(Cell())
        }
    }

    // MARK: Operations

    /// Fill the whole pool from a new asset source.
    func setNewSource(_ source: AssetSource, originIndex: Int,
                      originPosition: CellPosition, positionEnds: PositionEnds) {
        cellsDictionary = [:]
        let range = availableIndexRange(source, originIndex: originIndex)

        currentOriginGlobal = originIndex
        currentOriginLocal = originIndex - range.min

        for indexLocal in 0..<cellsCount {
            setCellAtIndex(indexLocal, source: source,
                           globalOrigin: currentOriginGlobal, localOrigin: currentOriginLocal,
                           originPosition: originPosition, positionEnds: positionEnds)
        }
    }

    /// Rotate the ring buffer so the pool surrounds `newOrigin`. Only cells
    /// entering the window are (re)filled; the rest keep their textures.
    func moveOrigin(_ source: AssetSource, newOrigin: Int,
                    originPosition: CellPosition, positionEnds: PositionEnds) {
        let oldOrigin = currentOriginGlobal
        if oldOrigin == newOrigin {
            return
        }
        let oldMin = currentOriginGlobal - currentOriginLocal
        let range = availableIndexRange(source, originIndex: newOrigin)
        let move = range.min - oldMin

        currentOriginGlobal = newOrigin
        currentOriginLocal = newOrigin - range.min

        if move == 0 {
            return
        }

        var refreshCells = [Cell]()
        var refreshIndex = 0
        if move > 0 {
            var max = move - 1
            if max > cellsArray.count - 1 {
                max = cellsArray.count - 1
            }
            refreshCells += cellsArray[0...max]
            cellsArray[0...max] = []
            refreshIndex = cellsArray.count
            cellsArray += refreshCells
        } else {
            let max = cellsArray.count - 1
            var min = max + move + 1
            if min < 0 {
                min = 0
            }
            refreshCells += cellsArray[min...max]
            if min > 0 {
                var keepCells = [Cell]()
                keepCells += cellsArray[0..<min]
                cellsArray[0..<min] = []
                cellsArray += keepCells
            }
            refreshIndex = 0
        }

        let newOriginPosition = positionWithIndex(index: currentOriginGlobal, originIndex: oldOrigin,
                                                  originPosition: originPosition, positionEnds: positionEnds)

        if refreshCells.count > 0 {
            for indexDiscard in 0..<refreshCells.count {
                if let asset = refreshCells[indexDiscard].asset {
                    cellsDictionary.removeValue(forKey: asset)
                }
            }
            for indexLocal in refreshIndex..<(refreshIndex + refreshCells.count) {
                setCellAtIndex(indexLocal, source: source,
                               globalOrigin: currentOriginGlobal, localOrigin: currentOriginLocal,
                               originPosition: newOriginPosition, positionEnds: positionEnds)
            }
        }
    }

    func cellWithAsset(_ asset: PHAsset) -> Cell? {
        return cellsDictionary[asset]
    }

    func originCell() -> Cell? {
        if currentOriginLocal >= 0 && currentOriginLocal < cellsArray.count {
            let cell = cellsArray[currentOriginLocal]
            if cell.isEmpty == false {
                return cell
            }
        }
        return nil
    }

    /// Take over another manager's cells (used to keep the outgoing grid
    /// on screen while the new one animates in).
    func migrate(fromAnotherManager manager: CellManager, previous: Bool) {
        cellsDictionary = [:]
        manager.cellsDictionary = [:]
        for index in 0..<cellsArray.count {
            let cell = cellsArray[index]
            if index < manager.cellsArray.count {
                cell.migrate(from: manager.cellsArray[index])
                if previous {
                    cell.previousPosition = cell.position
                }
                if let asset = cell.asset {
                    cellsDictionary[asset] = cell
                } else if let cachingManager = cachingManager {
                    cell.clear(cachingManager)
                }
            } else if let cachingManager = cachingManager {
                cell.clear(cachingManager)
            }
        }
    }

    func clear() {
        guard let cachingManager = cachingManager else { return }
        for cell in cellsArray {
            cell.clear(cachingManager)
        }
    }

    func setAlpha(_ alpha: CGFloat) {
        for cell in cellsArray {
            cell.alpha = alpha
            cell.previousAlpha = alpha
        }
    }

    func setDestinationAlpha(_ alpha: CGFloat) {
        for cell in cellsArray {
            cell.alpha = alpha
        }
    }

    // MARK: Internals

    /// The window of asset indices the pool can hold, centered on the origin
    /// but clamped to the ends of the asset list.
    private func availableIndexRange(_ source: AssetSource, originIndex: Int) -> (min: Int, max: Int) {
        let rest = cellsCount % 2
        let halfCount = cellsCount / 2
        var indexMin = originIndex - halfCount
        var indexMax = originIndex + halfCount - 1 + rest

        if indexMin < 0 {
            indexMin = 0
        }
        if indexMax >= source.count {
            let over = indexMax - (source.count - 1)
            var vacant = indexMin
            if vacant > over {
                vacant = over
            }
            indexMin -= vacant
            indexMax -= vacant
            if indexMax >= source.count {
                indexMax = source.count - 1
            }
        }
        return (indexMin, indexMax)
    }

    private func setCellAtIndex(_ indexLocal: Int, source: AssetSource,
                                globalOrigin: Int, localOrigin: Int,
                                originPosition: CellPosition, positionEnds: PositionEnds) {
        guard indexLocal >= 0 && indexLocal < cellsArray.count else { return }
        guard let cachingManager = cachingManager else { return }

        let relativeOrigin = globalOrigin - localOrigin
        let cell = cellsArray[indexLocal]
        let indexFetch = indexLocal + relativeOrigin

        if indexFetch >= 0 && indexFetch < source.count, let asset = source.asset(at: indexFetch) {
            cell.clear(cachingManager)
            cell.isEmpty = false
            cell.asset = asset
            cell.position = positionWithIndex(index: indexFetch, originIndex: globalOrigin,
                                              originPosition: originPosition, positionEnds: positionEnds)
            cell.positionIsNull = false
            cell.previousPosition = cell.position
            cell.index = indexFetch
            cellsDictionary[asset] = cell
        } else {
            cell.clear(cachingManager)
        }
    }
}

// MARK: - Cell

/// One slot in the pool: an image view plus its multi-resolution textures,
/// in-flight request IDs and grid positions (current and previous, for
/// animating between layouts).
private final class Cell {

    /// Loaded images at each resolution level (0 = small, 1 = medium, 2 = large).
    final class Texture {
        var small: UIImage?
        var medium: UIImage?
        var large: UIImage?

        func level(_ level: Int) -> UIImage? {
            switch level {
            case 0: return small
            case 1: return medium
            case 2: return large
            default: return small
            }
        }

        func copy(from master: Texture) {
            small = master.small
            medium = master.medium
            large = master.large
        }

        func set(_ image: UIImage?, level: Int) {
            switch level {
            case 0: small = image
            case 1: medium = image
            case 2: large = image
            default: small = image
            }
        }

        /// Remove the given level and every level above it (higher levels
        /// are bigger, so this frees the most memory first).
        func remove(fromLevel level: Int) {
            if level <= 0 { small = nil }
            if level <= 1 { medium = nil }
            if level <= 2 { large = nil }
        }

        func removeAll() {
            small = nil
            medium = nil
            large = nil
        }
    }

    /// In-flight PHImageManager request IDs per resolution level.
    final class RequestIDs {
        var small: PHImageRequestID?
        var medium: PHImageRequestID?
        var large: PHImageRequestID?

        func isNil(atLevel level: Int) -> Bool {
            switch level {
            case 0: return small == nil
            case 1: return medium == nil
            case 2: return large == nil
            default: return true
            }
        }

        func set(_ anID: PHImageRequestID?, level: Int) {
            switch level {
            case 0: small = anID
            case 1: medium = anID
            case 2: large = anID
            default: small = anID
            }
        }

        func copy(from master: RequestIDs) {
            small = master.small
            medium = master.medium
            large = master.large
        }

        func deleteAll() {
            small = nil
            medium = nil
            large = nil
        }

        /// Cancel the given level and every level above it.
        func cancel(fromLevel level: Int, manager: PHCachingImageManager) {
            if level == 0, let id = small {
                manager.cancelImageRequest(id)
                small = nil
            }
            if level <= 1, let id = medium {
                manager.cancelImageRequest(id)
                medium = nil
            }
            if level <= 2, let id = large {
                manager.cancelImageRequest(id)
                large = nil
            }
        }

        func cancelAll(_ manager: PHCachingImageManager) {
            if let id = small {
                manager.cancelImageRequest(id)
                small = nil
            }
            if let id = medium {
                manager.cancelImageRequest(id)
                medium = nil
            }
            if let id = large {
                manager.cancelImageRequest(id)
                large = nil
            }
        }
    }

    var asset: PHAsset?
    var index: Int = 0
    let imageView = UIImageView()
    var imageProportion: CGFloat = 1 // image height / width
    var cellProportion: CGFloat = 1  // slot height / width

    var texture = Texture()
    var requestIDs = RequestIDs()

    var position = CellPosition()
    var previousPosition = CellPosition()
    var positionIsNull = true
    var alpha: CGFloat = 1
    var previousAlpha: CGFloat = 1
    var isEmpty = true

    deinit {
        imageView.removeFromSuperview()
    }

    // MARK: Recycling

    /// Copy everything (including the loaded textures and the on-screen
    /// image view state) from another cell, then reset that cell.
    func migrate(from cell: Cell) {
        requestIDs.copy(from: cell.requestIDs)
        texture.copy(from: cell.texture)

        asset = cell.asset
        index = cell.index
        imageView.image = cell.imageView.image
        if let superView = cell.imageView.superview {
            imageView.frame = cell.imageView.frame
            cell.imageView.removeFromSuperview()
            superView.addSubview(imageView)
        }

        imageProportion = cell.imageProportion
        position = cell.position
        previousPosition = cell.previousPosition
        positionIsNull = cell.positionIsNull
        isEmpty = cell.isEmpty
        alpha = cell.alpha
        previousAlpha = cell.previousAlpha

        updateImageViewProportion()

        // Reset the donor cell (without cancelling the requests we adopted).
        cell.requestIDs.deleteAll()
        cell.asset = nil
        cell.index = 0
        cell.imageView.image = nil
        cell.imageView.removeFromSuperview()
        cell.imageProportion = 1
        cell.texture.removeAll()
        cell.position = CellPosition()
        cell.previousPosition = CellPosition()
        cell.positionIsNull = true
        cell.isEmpty = true
        cell.alpha = 1
        cell.previousAlpha = 1
    }

    func clear(_ manager: PHCachingImageManager) {
        imageView.removeFromSuperview()
        requestIDs.cancelAll(manager)
        asset = nil
        index = 0
        imageView.image = nil
        imageProportion = 1
        texture.removeAll()
        position = CellPosition()
        previousPosition = CellPosition()
        positionIsNull = true
        isEmpty = true
        alpha = 1
        previousAlpha = 1
    }

    func removeTexture(fromLevel level: Int, manager: PHCachingImageManager) {
        if requestIDs.isNil(atLevel: level) == false {
            requestIDs.cancel(fromLevel: level, manager: manager)
            texture.remove(fromLevel: level)
            setImage()
        }
    }

    // MARK: Alpha

    func animatedAlpha(_ animatePoint: Float) -> CGFloat {
        return mergeCGFloatValues(previousAlpha, valueB: alpha, mergePoint: CGFloat(animatePoint))
    }

    func setImageViewAlpha(_ animatePoint: Float) {
        imageView.alpha = animatedAlpha(animatePoint)
    }

    // MARK: Position animation

    /// The cell's grid position at animation point `animatePoint`, moving
    /// between `previousPosition` and `position`. When a layout change also
    /// changes the number of columns, cells flow along the reading order --
    /// running to a row end, jumping to the start of the next row -- instead
    /// of moving in a straight line. This is what produces the characteristic
    /// "reflow" animation when pinching.
    func animatedPosition(_ animatePoint: Float, rowEnds: PositionEnds,
                          previousRowEnds: PositionEnds) -> CellPosition {
        if animatePoint >= 1 {
            return position
        }

        let rowMax = rowEnds.rightEnd + 1
        let rowMin = rowEnds.leftEnd - 1
        let previousRowMax = previousRowEnds.rightEnd + 1
        let previousRowMin = previousRowEnds.leftEnd - 1

        var resultPosition = CellPosition()
        let rowRange = rowMax - rowMin + 1
        let middleColumnRange = abs(position.column - previousPosition.column) - 1

        var rowRangeInSameColumnCase: Float = 0
        var startRow: Float = 0
        var endRow: Float = 0
        var additionalStartRow: Float = 0
        var additionalEndRow: Float = 0
        var direction = true

        if middleColumnRange == -1 {
            // Same row of the grid: simple linear interpolation.
            resultPosition = position
            if previousPosition.row > position.row {
                rowRangeInSameColumnCase = previousPosition.row - position.row
                resultPosition.row = previousPosition.row - (rowRangeInSameColumnCase * animatePoint)
                return resultPosition
            } else {
                rowRangeInSameColumnCase = position.row - previousPosition.row
                resultPosition.row = previousPosition.row + (rowRangeInSameColumnCase * animatePoint)
                return resultPosition
            }
        } else {
            var positionEndsDifference: Float = 0
            var endPositionEndsDifference: Float = 0
            if previousPosition.column < position.column {
                direction = true
                startRow = rowMax - previousPosition.row - 1
                endRow = position.row - rowMin - 1
                positionEndsDifference = previousRowMax - rowMax
                endPositionEndsDifference = rowMin - previousRowMin
            } else {
                direction = false
                startRow = previousPosition.row - rowMin - 1
                endRow = rowMax - position.row - 1
                positionEndsDifference = rowMin - previousRowMin
                endPositionEndsDifference = previousRowMax - rowMax
            }
            if positionEndsDifference < 0 {
                positionEndsDifference = 0
            }
            if startRow < 0 {
                additionalStartRow = positionEndsDifference + startRow
                startRow = 0
            }
            if endRow < 0 {
                additionalEndRow = endPositionEndsDifference + endRow
                endRow = 0
            }
            startRow += 2
            endRow += 2
        }

        let middleValue = (rowRange * Float(middleColumnRange)) + additionalStartRow + additionalEndRow
        let wholeValue = middleValue + startRow + endRow
        let animatedValue = wholeValue * animatePoint
        if middleColumnRange == 0 {
            endRow += additionalStartRow
            startRow += additionalEndRow
        }

        if direction {
            if animatedValue <= startRow {
                resultPosition = previousPosition
                resultPosition.row += animatedValue
                return resultPosition
            } else if animatedValue >= wholeValue - endRow {
                resultPosition = position
                resultPosition.row -= wholeValue - animatedValue
                return resultPosition
            }
            resultPosition = previousPosition
            resultPosition.column += Int64(Int((animatedValue - startRow) / rowRange) + 1)
            if animatedValue > startRow + rowRange + additionalStartRow {
                additionalStartRow = 0
            }
            if animatedValue < startRow + middleValue - rowRange - additionalEndRow {
                additionalEndRow = 0
            }
            resultPosition.row = rowMin + fmodf(animatedValue - startRow,
                                                rowRange + additionalStartRow + additionalEndRow)
            return resultPosition
        } else {
            if animatedValue <= startRow {
                resultPosition = previousPosition
                resultPosition.row -= animatedValue
                return resultPosition
            } else if animatedValue >= wholeValue - endRow {
                resultPosition = position
                resultPosition.row += wholeValue - animatedValue
                return resultPosition
            }
            resultPosition = previousPosition
            resultPosition.column -= Int64(Int((animatedValue - startRow) / rowRange) + 1)
            if animatedValue > startRow + rowRange + additionalStartRow {
                additionalStartRow = 0
            }
            if animatedValue < startRow + middleValue - rowRange - additionalEndRow {
                additionalEndRow = 0
            }
            resultPosition.row = rowMax - fmodf(animatedValue - startRow,
                                                rowRange + additionalStartRow + additionalEndRow)
            return resultPosition
        }
    }

    // MARK: Image

    /// Show the best texture currently loaded.
    func setImage() {
        if let img = texture.large {
            imageView.image = img
            if img.size.height > 0 && img.size.width > 0 {
                imageProportion = img.size.height / img.size.width
            }
        } else if let img = texture.medium {
            imageView.image = img
            if img.size.height > 0 && img.size.width > 0 {
                imageProportion = img.size.height / img.size.width
            }
        } else if let img = texture.small {
            imageView.image = img
            if img.size.height > 0 && img.size.width > 0 {
                imageProportion = img.size.height / img.size.width
            }
        } else {
            imageView.image = nil
            imageProportion = 1
        }
        updateImageViewProportion()
    }

    /// Refit the image view inside its slot for the current image aspect.
    func updateImageViewProportion() {
        let slotAspect = CGSize(width: 1, height: cellProportion)
        var resultRect = enclosingRect(aspect: slotAspect, around: imageView.frame)
        if imageProportion > 1 {
            resultRect.size.width /= imageProportion
            resultRect.origin.x += (resultRect.size.height - resultRect.size.width) / 2
        } else {
            resultRect.size.height *= imageProportion
            resultRect.origin.y += (resultRect.size.width - resultRect.size.height) / 2
        }
        imageView.frame = resultRect
    }

    // MARK: Rects

    /// The on-screen rect of the cell's content (aspect-fitted inside its
    /// grid slot) at the given animation point.
    func contentRect(_ originRect: CGRect, originPosition: CellPosition, animatePoint: Float,
                     rowEnds: PositionEnds, previousRowEnds: PositionEnds) -> CGRect {
        var resultRect = animatedRect(originRect, originPosition: originPosition,
                                      animatePoint: animatePoint,
                                      rowEnds: rowEnds, previousRowEnds: previousRowEnds)
        if imageProportion > 1 {
            resultRect.size.width /= imageProportion
            resultRect.origin.x += (resultRect.size.height - resultRect.size.width) / 2
        } else {
            resultRect.size.height *= imageProportion
            resultRect.origin.y += (resultRect.size.width - resultRect.size.height) / 2
        }
        return resultRect
    }

    func animatedRect(_ originRect: CGRect, originPosition: CellPosition, animatePoint: Float,
                      rowEnds: PositionEnds, previousRowEnds: PositionEnds) -> CGRect {
        return rectWithPosition(animatedPosition(animatePoint, rowEnds: rowEnds,
                                                 previousRowEnds: previousRowEnds),
                                originRect: originRect, originPosition: originPosition)
    }

    func rect(_ originRect: CGRect, originPosition: CellPosition) -> CGRect {
        return rectWithPosition(position, originRect: originRect, originPosition: originPosition)
    }
}

// MARK: - Grid geometry

/// A cell's place in the grid.
/// `column` is the vertical row number (Int64 so huge libraries never
/// overflow); `row` is the horizontal slot within that row (Float, because
/// during a pinch the grid can sit between whole slots).
private struct CellPosition {
    var column: Int64 = 0
    var row: Float = 0
}

/// Horizontal extent of a grid row, in `row` units relative to the layout
/// origin: which slot is the left end of a row and which is the right end.
private struct PositionEnds {
    var leftEnd: Float = 0
    var rightEnd: Float = 0
}

private func relativePositionEnds(_ positionEnds: PositionEnds,
                                  originPosition: CellPosition) -> PositionEnds {
    return PositionEnds(leftEnd: positionEnds.leftEnd - originPosition.row,
                        rightEnd: positionEnds.rightEnd - originPosition.row)
}

private func rectWithIndex(_ index: Int, originRect: CGRect, originIndex: Int,
                           originPosition: CellPosition, positionEnds: PositionEnds) -> CGRect {
    let position = positionWithIndex(index: index, originIndex: originIndex,
                                     originPosition: originPosition, positionEnds: positionEnds)
    return rectWithPosition(position, originRect: originRect, originPosition: originPosition)
}

/// The grid position of an arbitrary asset index, given where the origin
/// asset sits and how wide the rows are. Walks forward or backward through
/// the reading order, wrapping at row ends.
private func positionWithIndex(index cellIndex: Int, originIndex: Int,
                               originPosition: CellPosition,
                               positionEnds: PositionEnds) -> CellPosition {
    let relativeIndex = cellIndex - originIndex
    if relativeIndex == 0 {
        return originPosition
    }
    let relativeEnds = relativePositionEnds(positionEnds, originPosition: originPosition)
    let endWidth = positionEnds.rightEnd - positionEnds.leftEnd + 1

    var count = abs(relativeIndex)
    var relativePosition = CellPosition()
    if relativeIndex > 0 {
        count -= Int(relativeEnds.leftEnd) - 1
        relativePosition.row = Float((count % Int(endWidth)) - 1)
        if relativePosition.row < 0 {
            relativePosition.row = endWidth - 1
        }
        relativePosition.row += relativeEnds.leftEnd
        relativePosition.column = Int64(Float(count - 1) / endWidth)
    } else {
        count += Int(relativeEnds.rightEnd)
        relativePosition.row = endWidth - Float((count % Int(endWidth)) + 1)
        relativePosition.column = -Int64(Float(count - 1) / endWidth)
        if relativePosition.row == endWidth - 1 {
            relativePosition.column -= 1
        }
        relativePosition.row += relativeEnds.leftEnd
    }

    return CellPosition(column: relativePosition.column + originPosition.column,
                        row: relativePosition.row + originPosition.row)
}

private func rectWithPosition(_ position: CellPosition, originRect: CGRect,
                              originPosition: CellPosition) -> CGRect {
    var resultRect = originRect
    let relative = relativePosition(position, origin: originPosition)
    resultRect.origin.x += originRect.size.width * CGFloat(relative.row)
    resultRect.origin.y += originRect.size.height * CGFloat(relative.column)
    return resultRect
}

private func relativePosition(_ position: CellPosition, origin originPosition: CellPosition) -> CellPosition {
    var resultPosition = CellPosition()
    resultPosition.column = position.column - originPosition.column
    resultPosition.row = position.row - originPosition.row
    return resultPosition
}

// MARK: - Touch stamps

private struct TouchStamp {
    let point: CGPoint
    let time: TimeInterval

    init(touch: UITouch, view: UIView) {
        point = touch.location(in: view)
        time = touch.timestamp
    }
}

// MARK: - Small geometry helpers

private func mergeCGFloatValues(_ valueA: CGFloat, valueB: CGFloat, mergePoint: CGFloat) -> CGFloat {
    return valueA + (valueB - valueA) * mergePoint
}

private func intermediateRect(_ startRect: CGRect, endRect: CGRect, mergePoint: CGFloat) -> CGRect {
    return CGRect(x: mergeCGFloatValues(startRect.origin.x, valueB: endRect.origin.x, mergePoint: mergePoint),
                  y: mergeCGFloatValues(startRect.origin.y, valueB: endRect.origin.y, mergePoint: mergePoint),
                  width: mergeCGFloatValues(startRect.size.width, valueB: endRect.size.width, mergePoint: mergePoint),
                  height: mergeCGFloatValues(startRect.size.height, valueB: endRect.size.height, mergePoint: mergePoint))
}

/// Scale a rect around its center.
private func resizeRect(_ rect: CGRect, scale: CGFloat) -> CGRect {
    var result = rect
    result.size.width *= scale
    result.size.height *= scale
    result.origin.x += (rect.size.width - result.size.width) / 2
    result.origin.y += (rect.size.height - result.size.height) / 2
    return result
}

/// Change a rect to a new size, keeping its center.
private func resizeRect(_ rect: CGRect, toSize size: CGSize) -> CGRect {
    var result = rect
    result.size = size
    result.origin.x += (rect.size.width - size.width) / 2
    result.origin.y += (rect.size.height - size.height) / 2
    return result
}

/// Scale a rect so the point at `anchorRatio` (0...1 in both axes) lands on
/// `anchorPoint`. Used to zoom around the pinch center.
private func resizeRect(_ rect: CGRect, scale: CGFloat,
                        anchorRatio: CGPoint, anchorPoint: CGPoint) -> CGRect {
    var result = rect
    result.size.width *= scale
    result.size.height *= scale
    result.origin.x = anchorPoint.x - anchorRatio.x * result.size.width
    result.origin.y = anchorPoint.y - anchorRatio.y * result.size.height
    return result
}

/// Clamp a rect horizontally into a frame (vertical position is scroll
/// state and must not be touched).
private func rectMovedInsideHorizontally(_ rect: CGRect, frame: CGRect) -> CGRect {
    var result = rect
    if result.maxX > frame.maxX {
        result.origin.x = frame.maxX - result.size.width
    }
    if result.minX < frame.minX {
        result.origin.x = frame.minX
    }
    return result
}

/// The smallest rect with the given aspect ratio (height / width taken from
/// `aspect`) that encloses `rect`, keeping it centered.
private func enclosingRect(aspect: CGSize, around rect: CGRect) -> CGRect {
    guard aspect.width > 0, aspect.height > 0, rect.width > 0 else { return rect }
    let targetRatio = aspect.height / aspect.width
    var result = rect
    if rect.height / rect.width > targetRatio {
        result.size.width = rect.height / targetRatio
        result.origin.x -= (result.size.width - rect.size.width) / 2
    } else {
        result.size.height = rect.width * targetRatio
        result.origin.y -= (result.size.height - rect.size.height) / 2
    }
    return result
}

private func pointRatio(_ point: CGPoint, in rect: CGRect) -> CGPoint {
    guard rect.size.width > 0, rect.size.height > 0 else { return .zero }
    return CGPoint(x: (point.x - rect.origin.x) / rect.size.width,
                   y: (point.y - rect.origin.y) / rect.size.height)
}

private func midPoint(_ pointA: CGPoint, _ pointB: CGPoint) -> CGPoint {
    return CGPoint(x: (pointA.x + pointB.x) / 2, y: (pointA.y + pointB.y) / 2)
}

private func distanceBetween(_ pointA: CGPoint, _ pointB: CGPoint) -> CGFloat {
    return hypot(pointB.x - pointA.x, pointB.y - pointA.y)
}

private func originDelta(from rectA: CGRect, to rectB: CGRect) -> CGPoint {
    return CGPoint(x: rectB.origin.x - rectA.origin.x, y: rectB.origin.y - rectA.origin.y)
}

/// Rubber-band curve: approximately linear for small values, asymptotically
/// approaching `scale` for large ones.
private func rubberBand(_ value: Double, scale: Double) -> Double {
    guard scale > 0, value > 0 else { return 0 }
    return scale * value / (value + scale)
}
