import SwiftUI

/// Something shown beside the main sheet, wide open on a Duo: a panel on the map half,
/// where a phone would put a second sheet over the list it is about.
struct PaneItem: Identifiable {
    let id: String
    var height: CGFloat = 380
    let content: AnyView
    let onClose: () -> Void
}

/// How a view shown in a pane or panel closes itself. Nil in an ordinary sheet, which uses `dismiss`.
struct PaneClose: Sendable {
    let run: @MainActor @Sendable () -> Void
}

extension EnvironmentValues {
    @Entry var paneClose: PaneClose? = nil
    /// Inside a second sheet: what would be lost if it moved into the pane as the phone opens.
    @Entry var paneDraft: PaneDraft? = nil
}

/// What a second sheet holds that a move into the pane would lose: typed text, a page pushed
/// inside it, a sheet opened from it. Each view that holds something adds itself.
@MainActor @Observable
final class PaneDraft {
    fileprivate var keeping: Set<UUID> = []
    var isKept: Bool { !keeping.isEmpty }
    func keep(_ id: UUID, _ keep: Bool) {
        if keep { keeping.insert(id) } else { keeping.remove(id) }
    }
}

extension View {
    /// In a second sheet opened on the Duo's cover: while `keep` is true the sheet stays as it
    /// is when the phone opens, so nothing is lost; otherwise it moves into the pane, off the fold.
    func keepsSheetWhenUnfolded(_ keep: Bool) -> some View { modifier(KeepsSheet(keep: keep)) }
}

private struct KeepsSheet: ViewModifier {
    var keep: Bool
    @Environment(\.paneDraft) private var draft
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onChange(of: keep, initial: true) { _, keep in draft?.keep(id, keep) }
            .onAppear { draft?.keep(id, keep) }
            .onDisappear { draft?.keep(id, false) }
    }
}

extension DismissAction {
    /// Closes a view opened as a pane page or panel, or dismisses the sheet it otherwise is.
    @MainActor func callAsFunction(or paneClose: PaneClose?) {
        if let paneClose { paneClose.run() } else { self() }
    }
}

/// Stands in for "is presented" where a sheet is driven by a flag rather than an item.
private struct Shown: Identifiable {
    let id = 0
}

private extension Binding where Value == Bool {
    var shown: Binding<Shown?> {
        Binding<Shown?>(get: { wrappedValue ? Shown() : nil }, set: { wrappedValue = $0 != nil })
    }
}

extension View {
    /// A sheet on a phone. Wide open on a Duo, a page laid over the leading pane: the system
    /// keeps a second sheet 650 pt wide and centred on the fold, whatever size is asked for.
    func paneSheet<Item: Identifiable, Sheet: View>(item: Binding<Item?>, id: String,
                                                    @ViewBuilder content: @escaping (Item) -> Sheet) -> some View {
        modifier(PaneSheetModifier(item: item, id: id, sheet: content))
    }

    func paneSheet<Sheet: View>(isPresented: Binding<Bool>, id: String, @ViewBuilder content: @escaping () -> Sheet) -> some View {
        modifier(PaneSheetModifier(item: isPresented.shown, id: id, sheet: { _ in content() }))
    }

    func mapPanel<Panel: View>(isPresented: Binding<Bool>, id: String, height: CGFloat = 380,
                               @ViewBuilder content: @escaping () -> Panel) -> some View {
        modifier(MapPanelModifier(item: isPresented.shown, id: id, height: height, sheetWhenFolded: true, panel: { _ in content() }))
    }
}

private struct PaneSheetModifier<Item: Identifiable, Sheet: View>: ViewModifier {
    @Binding var item: Item?
    var id: String
    @ViewBuilder var sheet: (Item) -> Sheet
    @Environment(Router.self) private var router
    /// Set when this is opened from inside another second sheet, which keeps that one where it is.
    @Environment(\.paneDraft) private var parentDraft
    /// How it opened: a sheet on the cover, or a page in the pane wide open.
    @State private var asSheet = false
    @State private var inPane = false
    @State private var draft = PaneDraft()
    @State private var selfID = UUID()

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { inPane || (router.foldX != nil && !asSheet) ? nil : item },
                                 // Moving into the pane takes the sheet down; that is not a dismissal.
                                 set: { if $0 != nil || !inPane { item = $0 } })) {
                // A sheet closes itself, even when the page that opened it is in the pane.
                sheet($0)
                    .environment(\.paneClose, nil)
                    .environment(\.paneDraft, draft)
                    .onAppear { asSheet = true }
            }
            .onChange(of: item.map { AnyHashable($0.id) }, initial: true) { _, _ in
                parentDraft?.keep(selfID, item != nil)
                if let item {
                    guard router.foldX != nil, !asSheet else { return }
                    showInPane(item)
                } else {
                    if inPane { router.hideCover(id) }
                    inPane = false
                    asSheet = false
                    draft = PaneDraft()
                }
            }
            // Opened on the cover, then the phone opened wide: with nothing typed or opened in it,
            // the sheet moves into the pane, off the fold. Otherwise it stays, so nothing is lost.
            .onChange(of: router.foldX != nil) { _, open in
                guard open, let item, asSheet, !inPane, parentDraft == nil, !draft.isKept else { return }
                asSheet = false
                showInPane(item)
            }
    }

    private func showInPane(_ item: Item) {
        inPane = true
        router.show(cover: PaneItem(id: id, content: AnyView(sheet(item)), onClose: { self.item = nil }))
    }
}

/// Pages laid over the pane, each over the one that opened it.
struct PaneCovers: View {
    @Environment(Router.self) private var router

    var body: some View {
        ZStack {
            ForEach(router.covers) { cover in
                cover.content
                    .environment(\.paneClose, PaneClose { [router, id = cover.id] in router.close(id) })
                    .background(Theme.paper)
                    // Modal, as the same page is as a sheet on a phone: VoiceOver and the accessibility
                    // tree keep to the page on top, not the covered ones under it.
                    .accessibilityAddTraits(cover.id == router.covers.last?.id ? .isModal : [])
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.snappy, value: router.covers.map(\.id))
    }
}

extension View {
    /// A sheet on a phone. Wide open on a Duo, a panel docked on the map half, beside the
    /// list it changes rather than over it. `sheetWhenFolded: false` is for a panel whose
    /// folded form is a pushed page, not a sheet.
    func mapPanel<Item: Identifiable, Panel: View>(item: Binding<Item?>, id: String, height: CGFloat = 380,
                                                   sheetWhenFolded: Bool = true,
                                                   @ViewBuilder content: @escaping (Item) -> Panel) -> some View {
        modifier(MapPanelModifier(item: item, id: id, height: height, sheetWhenFolded: sheetWhenFolded, panel: content))
    }
}

private struct MapPanelModifier<Item: Identifiable, Panel: View>: ViewModifier {
    @Binding var item: Item?
    var id: String
    var height: CGFloat
    var sheetWhenFolded: Bool
    @ViewBuilder var panel: (Item) -> Panel
    @Environment(Router.self) private var router

    private struct Showing: Equatable {
        var item: AnyHashable?
        var inPane: Bool
    }

    func body(content: Content) -> some View {
        content
            // Unfolding takes the sheet down to show the panel instead; that is not a dismissal.
            .sheet(item: Binding(get: { router.isPane || !sheetWhenFolded ? nil : item },
                                 set: { if $0 != nil || !router.isPane { item = $0 } })) {
                panel($0).environment(\.paneClose, nil)
            }
            .onChange(of: Showing(item: item.map { AnyHashable($0.id) }, inPane: router.isPane), initial: true) { _, now in
                if let item, now.inPane {
                    router.show(panel: PaneItem(id: id, height: height, content: AnyView(panel(item)), onClose: { self.item = nil }))
                } else {
                    router.hidePanel(id)
                }
            }
            // The page it belongs to has gone (Back, or a page pushed over it).
            .onDisappear {
                item = nil
                router.hidePanel(id)
            }
    }
}

/// The map half's own layer, wide open: a panel docked at its foot, clear of the fold and
/// the system's column. The whole-map button is in the map's lane of buttons (`MapButtons`).
struct MapHalf: View {
    @Environment(Router.self) private var router

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let foldX = router.foldX, router.isPane, let panel = router.panel {
                panel.content
                    .environment(\.paneClose, PaneClose { [router, id = panel.id] in router.close(id) })
                    // Its leading edge 24 pt past the fold, clear of the crease.
                    .frame(width: max(280, router.windowSize.width - foldX - router.safeArea.trailing - 40), height: panel.height)
                    .background(Theme.paper)
                    .clipShape(.rect(cornerRadius: 26))
                    .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(Theme.hairline, lineWidth: 0.75))
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
                    .foregroundStyle(Theme.ink)
                    .padding(8)
                    .id(panel.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: router.panel?.id)
    }
}

extension View {
    /// The sheet at its low rest, the 88 pt bar of a short window: this page's own bar, drawn for
    /// that rest, in place of whatever its list was scrolled to. With no bar given, the navigation
    /// bar above is the page's bar and what is under it is covered.
    func lowRestBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View { modifier(LowRestBar(bar: bar())) }

    func lowRestBar() -> some View { lowRestBar { EmptyView() } }
}

private struct LowRestBar<Bar: View>: ViewModifier {
    let bar: Bar
    @Environment(Router.self) private var router

    private var isLow: Bool { router.detent == Router.low }

    func body(content: Content) -> some View {
        content
            // Faded rather than covered: at this height a list draws on past the sheet's foot.
            .opacity(isLow ? 0 : 1)
            .accessibilityHidden(isLow)
            .overlay {
                if isLow {
                    // The whole card, not the room under a navigation bar that draws nothing here:
                    // centred under the grabber, with as much space below the row as above it.
                    // On the cover it runs under the system's column too, so a button can sit
                    // in the column's lane, as the map's capsule above does.
                    bar
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, LowBar.grabber)
                        .padding(.bottom, router.foldX != nil ? LowBar.paneFootOverhang : 0)
                        .ignoresSafeArea(.container, edges: router.barIsBeside ? [.top, .bottom, .trailing] : [.top, .bottom])
                        .transition(.opacity)
                }
            }
            .animation(.snappy(duration: 0.2), value: isLow)
    }
}

/// The put-away bar's measures.
enum LowBar {
    /// The top of the card the grabber takes, which the row is centred below.
    static let grabber: CGFloat = 10
    /// Wide open the pane's frame runs on about 5 pt past the card's visible foot (measured on the
    /// simulator; the cover's card and frame end together), which would sit the row that much low.
    static let paneFootOverhang: CGFloat = 5
    /// On the cover the put-away card ends in the column's lane, about 80 pt tall: a 44 pt button
    /// this far from its end sits in the middle of its rounded end, where the system's own column
    /// button sat.
    static let endInset: CGFloat = 22
}
