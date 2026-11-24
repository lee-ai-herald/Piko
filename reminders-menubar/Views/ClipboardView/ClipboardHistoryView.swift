import SwiftUI

@MainActor
struct ClipboardHistoryView: View {
    var isMiniMode: Bool = false

    @ObservedObject private var store = ClipboardHistoryStore.shared
    @State private var searchText = ""
    @State private var showPinnedOnly = false

    private var filteredItems: [ClipboardItem] {
        let base = showPinnedOnly ? store.sortedItems.filter(\.isPinned) : store.sortedItems
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return base }
        return base.filter { $0.searchableText.lowercased().contains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchAndFilterBar

            Divider().opacity(0.5)

            if filteredItems.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 6) {
                        ForEach(filteredItems) { item in
                            ClipboardItemRow(
                                item: item,
                                isJustCopied: store.lastCopiedItemId == item.id
                            )
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private var searchAndFilterBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                TextField("搜索历史复制内容…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )

            Button {
                showPinnedOnly.toggle()
            } label: {
                Image(systemName: showPinnedOnly ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundColor(showPinnedOnly ? .orange : .secondary)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(showPinnedOnly ? Color.orange.opacity(0.14) : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .help(showPinnedOnly ? "显示全部历史" : "只看已收藏")

            Button {
                store.clearUnpinned()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(store.items.allSatisfy(\.isPinned))
            .help("清空未收藏的历史记录")
        }
        .padding(.horizontal, isMiniMode ? 9 : 12)
        .padding(.vertical, isMiniMode ? 7 : 9)
    }

    private var emptyState: some View {
        let title: String = {
            if !searchText.isEmpty { return "没有找到匹配的记录" }
            return showPinnedOnly ? "暂无已收藏记录" : "暂无剪贴板历史"
        }()
        let subtitle: String = {
            if !searchText.isEmpty { return "换个关键词试试" }
            return showPinnedOnly ? "悬停记录后点击星标即可收藏置顶" : "平时按 ⌘C 复制文字或图片后会自动记录在这里"
        }()

        return VStack(spacing: 8) {
            Spacer()
            Image(systemName: showPinnedOnly && searchText.isEmpty ? "star" : "doc.on.clipboard")
                .font(.system(size: 28))
                .foregroundColor(.secondary.opacity(0.6))
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

@MainActor
private struct ClipboardItemRow: View {
    let item: ClipboardItem
    let isJustCopied: Bool

    @State private var isHovered = false

    private var store: ClipboardHistoryStore {
        ClipboardHistoryStore.shared
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                contentPreview

                HStack(spacing: 6) {
                    if item.isPinned {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                    }

                    Text(item.relativeTimeText)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)

                    if let app = item.sourceApp, !app.isEmpty {
                        Text("· \(app)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    if case .text(let value) = item.kind {
                        Text("· \(value.count) 字")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.8))
                    }

                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isJustCopied {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark")
                    Text("已复制")
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.green.opacity(0.14)))
            } else if isHovered {
                HStack(spacing: 4) {
                    Button {
                        store.togglePin(item)
                    } label: {
                        Image(systemName: item.isPinned ? "star.fill" : "star")
                            .font(.system(size: 11))
                            .foregroundColor(item.isPinned ? .orange : .secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help(item.isPinned ? "取消收藏" : "收藏置顶（清空时不删除）")

                    Button {
                        store.delete(item)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help("删除此条")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isJustCopied
                        ? Color.green.opacity(0.08)
                        : (isHovered ? Color.primary.opacity(0.08) : Color.primary.opacity(0.035))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isJustCopied ? Color.green.opacity(0.35) : Color.primary.opacity(isHovered ? 0.14 : 0.06),
                    lineWidth: 0.75
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            store.copyItem(item)
        }
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var contentPreview: some View {
        switch item.kind {
        case .text(let value):
            Text(value.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .lineLimit(3)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .image(let fileName, let width, let height):
            HStack(spacing: 8) {
                if let nsImage = store.thumbnail(for: fileName) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 120, maxHeight: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                Text("图片 (\(width)×\(height))")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }
}

#Preview {
    ClipboardHistoryView()
}
