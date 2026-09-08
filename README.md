# AssetGridView

A self-contained, single-file photo thumbnail grid for iOS, built directly on
the Photos framework (`PHAsset`). Extracted from a shipping photo viewer app.

Unlike a `UICollectionView`-based grid, this view implements its own
touch-driven scrolling and pinch zoom, which makes the two gestures fully
continuous and interruptible:

- **Scrolling** — inertia with hyperbolic decay, rubber-band resistance at
  the ends, and an overshoot-and-settle bounce.
- **Pinch zoom** — pinch anywhere to change the thumbnail size freely, with
  the cell under your fingers as the anchor. On release the grid snaps to a
  whole number of columns, and every thumbnail *reflows* to its new position
  along the reading order (running to the end of its row and wrapping),
  rather than sliding in a straight line.
- **Ring-buffer cell pool** — a fixed pool of cells (default 800) is
  recycled around the current scroll anchor, so memory stays bounded no
  matter how large the photo library is.
- **Multi-resolution thumbnails** — each cell holds small / medium / large
  textures requested through `PHCachingImageManager`. Tiny thumbnails are
  used while fast-scrolling; higher resolutions load as you zoom in, and are
  released again when no longer needed.

![screenshot](http://tomohiroyamashita.web.fc2.com/github/images/assetgridview00.png)



![screenshot](http://tomohiroyamashita.web.fc2.com/github/images/assetgridview05.png)

## Requirements

- iOS 13+ (Swift 5), UIKit, Photos framework
- `NSPhotoLibraryUsageDescription` in your Info.plist


## Original Product
[on the AppStore](https://apps.apple.com/us/app/albums-a-simple-album-editor/id1141304207)(Free).


## Installation

Copy `AssetGridView.swift` into your project. Everything except
`AssetGridView` and `AssetGridViewDelegate` is `private` to the file, so it
won't collide with existing types.

## Usage

```swift
import UIKit
import Photos

final class GalleryViewController: UIViewController, AssetGridViewDelegate {

    private let gridView = AssetGridView()

    override func viewDidLoad() {
        super.viewDidLoad()

        gridView.frame = view.bounds
        gridView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        gridView.delegate = self
        view.addSubview(gridView)

        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            guard status == .authorized || status == .limited else { return }
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            let assets = PHAsset.fetchAssets(with: options)
            DispatchQueue.main.async {
                self.gridView.setAssets(assets)
            }
        }
    }

    // MARK: AssetGridViewDelegate

    func assetGridView(_ gridView: AssetGridView, didSelect asset: PHAsset) {
        // Push your single-photo viewer here.
    }

    func assetGridView(_ gridView: AssetGridView, didChangeFocus asset: PHAsset?) {
        // Optional: track the asset at the scroll/zoom anchor.
    }
}
```

`setAssets` also accepts a plain `[PHAsset]` array. Calling it again performs
a transition: assets present in both the old and new sets keep their loaded
thumbnails and animate to their new positions; new ones fade in and removed
ones fade out. Use this from your `PHPhotoLibraryChangeObserver` to react to
library changes.

## API

| Member | Description |
| --- | --- |
| `setAssets(_: PHFetchResult<PHAsset>)` / `setAssets(_: [PHAsset])` | Set or replace the displayed assets (animated). |
| `clearAssets()` | Remove all assets (fade out). |
| `delegate` | Tap and focus-change callbacks. |
| `focusedAsset` | The asset at the current layout origin (scroll / pinch anchor). |
| `asset(at:)` | Hit-test a point to an asset. |
| `scrollTo(asset:animated:)` | Bring an asset to the vertical center. |
| `initialColumnCount` | Columns on first display (default 4). |
| `minimumColumnCount` | How far the user can pinch out (default 1). |
| `maximumThumbnailsAcrossShortEdge` | How far the user can pinch in (`nil` = 13 on iPhone, 25 on iPad). |
| `cellContentScale` | Thumbnail size as a fraction of its grid slot; controls the gap (default 0.97). |
| `contentMargin` | Margin around the grid (default 5). |
| `bottomInset` | Extra scrollable space below the last row. |
| `allowsNetworkAccess` | Allow iCloud downloads for missing thumbnails (default `true`). |

## Notes

- The grid opens scrolled to the **end** of the asset list (newest photo when
  sorted ascending by creation date), like the system Photos app.
- The view handles raw touches itself (`touchesBegan` etc.) rather than using
  gesture recognizers; if you embed it in a scroll view or add recognizers on
  top, you may need to arbitrate touch delivery yourself.
- Photo library authorization and change observation are intentionally out of
  scope — the view only renders what you pass to `setAssets`.

## License

MIT
