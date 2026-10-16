import SwiftUI
import AppKit
import AetherCore

struct SpaceLensView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let m = state.lens
        switch m.phase {
        case .idle:
            VStack(spacing: 0) {
                Hero(module: .spaceLens, headline: "Space Lens",
                     detail: "See what's using your storage as a map. Bigger blocks are bigger folders and files. Click to inspect, double-click to open a folder.",
                     button: "Scan Home Folder") { m.scan(FileManager.default.homeDirectoryForCurrentUser) }
                HStack(spacing: 10) {
                    Button("Applications") { m.scan(URL(fileURLWithPath: "/Applications")) }
                    Button("Choose Folder…") { chooseFolder(m) }
                }
                .buttonStyle(SoftButtonStyle()).padding(.bottom, 28)
            }
        case .scanning:
            ScanningView(module: .spaceLens, title: "Mapping \(m.root.lastPathComponent)", progress: m.progress) { m.cancel() }
        case .results:
            if let node = m.current { LensResults(model: m, node: node) }
        default:
            EmptyView()
        }
    }

    private func chooseFolder(_ m: SpaceLensModel) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        p.prompt = "Scan"
        if p.runModal() == .OK, let url = p.url { m.scan(url) }
    }
}

private struct Tile: Identifiable {
    var id: UUID { node.id }
    let node: DiskNode
    let rect: CGRect
    let depth: Int
}

private func buildTiles(for node: DiskNode, size: CGSize) -> [Tile] {
    let kids = node.children.filter { $0.size > 0 }
    let rects = Squarify.layout(sizes: kids.map { Double($0.size) }, in: CGRect(origin: .zero, size: size))
    var out: [Tile] = []
    for (k, r) in zip(kids, rects) {
        let outer = r.insetBy(dx: 1, dy: 1)
        guard outer.width > 1, outer.height > 1 else { continue }
        out.append(Tile(node: k, rect: outer, depth: 0))
        let ck = k.children.filter { $0.size > 0 }
        if k.isDirectory, !ck.isEmpty, outer.width > 96, outer.height > 64 {
            let header: CGFloat = 20
            let inner = CGRect(x: outer.minX + 3, y: outer.minY + header, width: outer.width - 6, height: outer.height - header - 3)
            let crs = Squarify.layout(sizes: ck.map { Double($0.size) }, in: inner)
            for (c, cr) in zip(ck, crs) where cr.width > 4 && cr.height > 4 {
                out.append(Tile(node: c, rect: cr.insetBy(dx: 0.5, dy: 0.5), depth: 1))
            }
        }
    }
    return out
}

private func tileColor(_ node: DiskNode, depth: Int) -> Color {
    if node.isOther { return Color(white: 0.5) }
    let key = node.isDirectory ? node.name : (node.url.pathExtension.lowercased())
    var h: UInt64 = 1469598103934665603
    for b in key.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
    let hue = Double(h % 360) / 360
    return Color(hue: hue, saturation: depth == 0 ? 0.52 : 0.42, brightness: depth == 0 ? 0.74 : 0.88)
}

private struct LensResults: View {
    @Bindable var model: SpaceLensModel
    let node: DiskNode
    @State private var hover: DiskNode?
    @State private var confirmTrash: DiskNode?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                GeometryReader { geo in
                    let tiles = buildTiles(for: node, size: geo.size)
                    TreemapCanvas(tiles: tiles, selection: model.selection, hover: hover, revision: model.revision)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let p): hover = hit(tiles, p)?.node
                            case .ended: hover = nil
                            }
                        }
                        .gesture(SpatialTapGesture(count: 2).onEnded { v in
                            if let t = hit(tiles, v.location)?.node {
                                model.selection = t
                                if t.canDrill { model.drill(t) }
                            }
                        })
                        .simultaneousGesture(SpatialTapGesture().onEnded { v in
                            model.selection = hit(tiles, v.location)?.node
                        })
                }
                .padding(10)
                Divider()
                Inspector(model: model, node: node, hover: hover) { confirmTrash = $0 }
                    .frame(width: 290)
            }
            statusBar
        }
        .confirmationDialog(confirmTrash.map { "Move \"\($0.name)\" to the Trash?" } ?? "", isPresented: Binding(
            get: { confirmTrash != nil }, set: { if !$0 { confirmTrash = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let n = confirmTrash { model.trash(n) }
                confirmTrash = nil
            }
        } message: {
            Text(confirmTrash.map { "\(Bytes.string($0.size)) · you can restore it from the Trash." } ?? "")
        }
    }

    private func hit(_ tiles: [Tile], _ p: CGPoint) -> Tile? {
        tiles.last { $0.rect.contains(p) }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { model.up() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(SoftButtonStyle()).disabled(node.parent == nil)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(node.path.enumerated()), id: \.element.id) { i, n in
                        if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                        Button(n.name) { model.current = n; model.selection = nil }
                            .buttonStyle(.plain)
                            .fontWeight(n === node ? .semibold : .regular)
                            .foregroundStyle(n === node ? .primary : .secondary)
                    }
                }
            }
            Spacer()
            Text(Bytes.string(node.size)).font(.headline).monospacedDigit()
            Button("Rescan") { model.scan() }.buttonStyle(SoftButtonStyle())
            Button("New Scan") { model.reset() }.buttonStyle(SoftButtonStyle())
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var statusBar: some View {
        HStack {
            if let msg = model.message {
                Text(msg).foregroundStyle(.secondary)
            } else if let h = hover {
                Text(h.name).fontWeight(.medium)
                Text("· \(Bytes.string(h.size))").foregroundStyle(.secondary)
                if node.size > 0 { Text("· \(Int((Double(h.size) / Double(node.size) * 100).rounded()))% of this folder").foregroundStyle(.secondary) }
            } else {
                Text("Hover a block to see its size.").foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .font(.callout).lineLimit(1)
        .padding(.horizontal, 28).padding(.vertical, 10)
        .background(.black.opacity(0.22))
    }
}

private struct TreemapCanvas: View {
    let tiles: [Tile]
    let selection: DiskNode?
    let hover: DiskNode?
    let revision: Int

    var body: some View {
        Canvas { ctx, _ in
            for t in tiles {
                let r = t.rect
                let color = tileColor(t.node, depth: t.depth)
                let path = Path(roundedRect: r, cornerRadius: t.depth == 0 ? 6 : 3)
                ctx.fill(path, with: .color(color))

                if t.depth == 0 {
                    let label = Text(t.node.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    let sub = Text(Bytes.string(t.node.size)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.85))
                    if r.width > 54, r.height > 20 {
                        ctx.drawLayer { l in
                            l.clip(to: Path(CGRect(x: r.minX + 6, y: r.minY + 3, width: r.width - 12, height: 16)))
                            l.draw(label, at: CGPoint(x: r.minX + 6, y: r.minY + 4), anchor: .topLeading)
                        }
                        if r.height > 40, t.node.children.isEmpty || r.width <= 96 || r.height <= 64 {
                            ctx.draw(sub, at: CGPoint(x: r.minX + 6, y: r.minY + 19), anchor: .topLeading)
                        }
                    }
                } else if r.width > 46, r.height > 16 {
                    ctx.drawLayer { l in
                        l.clip(to: Path(r.insetBy(dx: 2, dy: 1)))
                        l.draw(Text(t.node.name).font(.system(size: 9.5)).foregroundStyle(.black.opacity(0.7)),
                               at: CGPoint(x: r.minX + 4, y: r.minY + 2), anchor: .topLeading)
                    }
                }

                if t.node === selection {
                    ctx.stroke(path, with: .color(.white), lineWidth: 2.5)
                    ctx.stroke(Path(roundedRect: r.insetBy(dx: -1, dy: -1), cornerRadius: 6), with: .color(.accentColor), lineWidth: 1.5)
                } else if t.node === hover {
                    ctx.stroke(path, with: .color(.white.opacity(0.9)), lineWidth: 1.5)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.22)))
    }
}

private struct Inspector: View {
    let model: SpaceLensModel
    let node: DiskNode
    let hover: DiskNode?
    let trash: (DiskNode) -> Void

    var body: some View {
        let target = model.selection ?? node
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if target.isOther { Image(systemName: "square.grid.3x3").font(.title).frame(width: 40, height: 40).foregroundStyle(.secondary) }
                else { FileIcon(url: target.url, size: 40) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.name).font(.headline).lineLimit(2)
                    Text(Bytes.string(target.size)).font(.title3.weight(.semibold)).monospacedDigit()
                }
            }
            if !target.isOther {
                Text(target.url.tildePath).font(.caption).foregroundStyle(.secondary).lineLimit(3).truncationMode(.middle)
                HStack {
                    if target.canDrill { Button("Open") { model.drill(target) }.buttonStyle(SoftButtonStyle()) }
                    Button("Show in Finder") { reveal(target.url) }.buttonStyle(SoftButtonStyle())
                }
                if model.selection != nil {
                    Button {
                        trash(target)
                    } label: { Label("Move to Trash", systemImage: "trash") }
                        .buttonStyle(PrimaryButtonStyle(tint: Module.junk.tint))
                }
            } else {
                Text("Many items smaller than 1 MB, grouped to keep the map readable.").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text(model.selection == nil ? "Largest items here" : "Inside \(target.name)")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach((target.children.isEmpty ? [] : target.children).prefix(12)) { c in
                        Button { model.selection = c } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(c.name).lineLimit(1).font(.callout)
                                    Spacer()
                                    SizePill(bytes: c.size)
                                }
                                GeometryReader { g in
                                    RoundedRectangle(cornerRadius: 2).fill(tileColor(c, depth: 0))
                                        .frame(width: g.size.width * CGFloat(Double(c.size) / Double(max(target.size, 1))))
                                }.frame(height: 4)
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .id(model.revision)
    }
}
