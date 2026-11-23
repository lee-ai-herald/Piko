import SwiftUI
import EventKit

struct ReminderPriorityEditView: View {
    @Binding var priority: EKReminderPriority

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("优先级象限")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(EKReminderPriority.allQuadrants, id: \.rawValue) { quadrant in
                    quadrantButton(for: quadrant)
                }
            }
        }
    }

    @ViewBuilder
    private func quadrantButton(for quadrant: EKReminderPriority) -> some View {
        let isSelected = priority == quadrant
        let color = quadrant.quadrantColor

        Button {
            priority = quadrant
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)

                Text(quadrant.title)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .primary : .secondary)

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundColor(color)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? color.opacity(0.16) : Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isSelected ? color.opacity(0.65) : Color.primary.opacity(0.07), lineWidth: isSelected ? 1.2 : 0.75)
            )
        }
        .buttonStyle(.plain)
    }
}
