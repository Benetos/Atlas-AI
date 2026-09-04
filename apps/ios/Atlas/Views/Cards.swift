import SwiftUI

struct AtlasOpenLink<Label: View>: View {
    var destination: AppDestination
    var section: AppSection
    @ViewBuilder var label: () -> Label

    @Environment(AtlasRouter.self) private var router

    var body: some View {
        Button {
            router.open(destination, in: section)
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isLink)
    }
}

struct SourceBadge: View {
    var presentation: SourcePresentation
    var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(presentation.kind.title)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(badgeColor.opacity(0.2), in: Capsule())
            if expanded, let label = presentation.releaseLabel, !label.isEmpty {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Release \(label)")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var badgeColor: Color {
        switch presentation.kind {
        case .packed: .teal
        case .liveAtlas: .blue
        case .communityWeb: .orange
        }
    }
}

struct PlaceholderIcon: View {
    var entityType: String
    var colorR: String?
    var colorG: String?
    var colorB: String?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.22))
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
        }
        .frame(width: 44, height: 44)
        .accessibilityHidden(true)
    }

    private var symbol: String {
        EntityType(rawValue: entityType)?.systemImage ?? "square.dashed"
    }

    private var tint: Color {
        if let r = Double(colorR ?? ""), let g = Double(colorG ?? ""), let b = Double(colorB ?? "") {
            return Color(red: r, green: g, blue: b)
        }
        switch entityType {
        case "substance": return .orange
        case "technology": return .blue
        default: return .teal
        }
    }
}

struct AtlasCardShell<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(reduceTransparency ? AnyShapeStyle(Color.secondary.opacity(0.12)) : AnyShapeStyle(.thinMaterial))
            }
    }
}

struct EntityCardView: View {
    var entity: Entity
    var provenance: SourcePresentation?

    var body: some View {
        AtlasCardShell {
            HStack(alignment: .top, spacing: 12) {
                PlaceholderIcon(
                    entityType: entity.entityType,
                    colorR: entity.colorR,
                    colorG: entity.colorG,
                    colorB: entity.colorB
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(entity.title)
                        .font(.headline)
                    Text(entity.entityType.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let subtitle = entity.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let provenance {
                        SourceBadge(presentation: provenance)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct RecipeCardView: View {
    var recipe: Recipe
    var provenance: SourcePresentation?

    var body: some View {
        AtlasCardShell {
            VStack(alignment: .leading, spacing: 6) {
                Text(recipe.title)
                    .font(.headline)
                Text(recipe.recipeKind.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !recipe.ingredients.isEmpty {
                    Text(recipe.ingredients.map { $0.title ?? $0.gameID }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let provenance {
                    SourceBadge(presentation: provenance)
                }
            }
        }
    }
}

struct ContentCardView: View {
    var record: ContentRecord
    var provenance: SourcePresentation?

    var body: some View {
        AtlasCardShell {
            VStack(alignment: .leading, spacing: 6) {
                Text(record.title)
                    .font(.headline)
                Text(record.dataset.replacingOccurrences(of: "_", with: " "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let provenance {
                    SourceBadge(presentation: provenance)
                }
            }
        }
    }
}

struct WebCardView: View {
    var hit: WebHit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SourceBadge(
                presentation: SourcePresentation(kind: .communityWeb, releaseLabel: hit.host)
            )
            Text(hit.title)
                .font(.headline)
            Text(hit.host)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(hit.snippet)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.orange.opacity(0.4), lineWidth: 1)
        )
    }
}
