import SwiftUI

/// Reads the window's shape for the Duo: its size, whether the system has moved the
/// bars into a column at the side, and where the fold crosses it. Sits behind the map,
/// so it sees the whole window.
struct WindowShapeReader: View {
    @Environment(Router.self) private var router

    var body: some View {
        // The safe area is read from inside it; the window and the fold from the whole window.
        Color.clear
            .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { router.safeArea = $0 }
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onChange(of: proxy.size, initial: true) { _, size in router.windowSize = size }
                        .onChange(of: Self.fold(in: proxy), initial: true) { _, fold in
                            router.foldX = fold.x
                            router.foldY = fold.y
                        }
                }
                .ignoresSafeArea()
            }
            .background { if #available(iOS 27.1, *) { SideBarReader() } }
            .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private struct Fold: Equatable {
        var x: CGFloat?
        var y: CGFloat?
    }

    /// Where the fold crosses the window: down it at `x` wide open, across it at `y` turned
    /// tall. Neither on the cover, in a Split View half or on any other iPhone.
    private static func fold(in proxy: GeometryProxy) -> Fold {
        guard #available(iOS 27.1, *) else { return Fold() }
        // Flat open the fold is only a crease, which the system reports as inactive.
        guard let frame = proxy.reservedRegions(kind: .division, options: .includeInactive).first?.frame else { return Fold() }
        return frame.height > frame.width ? Fold(x: frame.midX) : Fold(y: frame.midY)
    }
}

@available(iOS 27.1, *)
private struct SideBarReader: View {
    @Environment(Router.self) private var router
    @Environment(\.toolbarVerticalEdge) private var edge

    var body: some View {
        Color.clear
            .onChange(of: edge != nil, initial: true) { _, sideBar in router.hasSideBar = sideBar }
            // Only whether it is partly open: there are no pose names, and no promised angles.
            .onHingeChange { _, new in router.hingeHalfOpen = new.hinge?.status == .partiallyOpen }
    }
}

enum FoldSide { case leading, trailing }

extension View {
    /// Wide open on a Duo a bottom sheet is centred, which puts its fields and buttons
    /// on the fold. This keeps the sheet to one half instead. With no fold in the
    /// window (`foldX` nil) the sheet is the system's own, unchanged.
    @ViewBuilder func sheetBesideFold(_ side: FoldSide, foldX: CGFloat?) -> some View {
        if #available(iOS 27.0, *) {
            presentationPlacement(foldX == nil ? .automatic : side == .leading ? .leading : .trailing)
                .presentationSizing(HalfSheetSizing(foldX: foldX))
        } else {
            self
        }
    }
}

/// A card on the leading half of the open Duo, stopping clearly short of the fold; the system's
/// size when there is no fold.
private struct HalfSheetSizing: PresentationSizing {
    var foldX: CGFloat?

    func proposedSize(for root: PresentationSizingRoot, context: PresentationSizingContext) -> ProposedViewSize {
        guard let foldX else { return AutomaticPresentationSizing.automatic.proposedSize(for: root, context: context) }
        // A card on the map that stops clearly short of the fold (420 pt wide, 47 pt short), not
        // a half that just misses it: the system adds its own margin to what is proposed.
        return ProposedViewSize(width: foldX - 55, height: nil)
    }
}
