import SwiftUI

/// The Neural Core: pick a mind, download it over the air, and Myna runs it
/// forever after with no network required.
struct ModelHubView: View {
    @EnvironmentObject private var modelManager: ModelManager

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header

                ForEach(ModelCatalog.all) { model in
                    ModelCard(model: model)
                }

                storageFooter
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
        .onAppear { modelManager.refreshInstalledStates() }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "cpu.fill")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(MynaTheme.auroraGradient)
                .shadow(color: MynaTheme.cyan.opacity(0.7), radius: 12)
                .padding(.top, 16)
            Text("Neural Core")
                .font(MynaTheme.display(24, weight: .bold))
                .auroraText()
            Text("Choose the mind behind Myna. Apple Intelligence is built in; the others download once from Hugging Face and run on this iPhone's GPU — offline, private, yours.")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
    }

    private var storageFooter: some View {
        HStack {
            Image(systemName: "internaldrive")
                .foregroundStyle(MynaTheme.gold)
            Text("On-device model storage: \(ByteCountFormatter.string(fromByteCount: modelManager.totalBytesOnDisk, countStyle: .file))")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
            Spacer()
        }
        .padding(16)
        .glassCard(cornerRadius: 18, glow: MynaTheme.gold)
    }
}

private struct ModelCard: View {
    let model: CatalogModel
    @EnvironmentObject private var modelManager: ModelManager

    private var state: ModelManager.ModelState { modelManager.state(of: model) }
    private var isActive: Bool { modelManager.activeModelID == model.id && installed }
    private var installed: Bool {
        switch state {
        case .installed, .ready, .loading: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.displayName)
                        .font(MynaTheme.display(17, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(model.family)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                if let badge = model.badge {
                    GlowChip(text: badge.rawValue, icon: badgeIcon(badge), tint: badgeTint(badge))
                }
            }

            Text(model.blurb)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.white.opacity(0.65))
                .lineSpacing(2)

            HStack(spacing: 8) {
                GlowChip(text: model.parameters, icon: "memorychip", tint: MynaTheme.cyan)
                if model.backend == .appleFoundation {
                    GlowChip(text: "No download", icon: "checkmark.seal", tint: MynaTheme.mint)
                    GlowChip(text: "Works when locked", icon: "lock.fill", tint: MynaTheme.magenta)
                } else {
                    GlowChip(text: String(format: "%.1f GB download", model.downloadGB), icon: "arrow.down", tint: MynaTheme.mint)
                    GlowChip(text: String(format: "~%.1f GB RAM", model.peakRAMGB), icon: "gauge.with.needle", tint: MynaTheme.magenta)
                }
            }

            if !model.fitsThisDevice {
                Label("Built for iPhones with \(Int(model.minimumDeviceRAMGB)) GB of memory — this one may run out.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(MynaTheme.gold)
            }

            actionRow
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 22, glow: isActive ? MynaTheme.mint : MynaTheme.cyan)
        .overlay(alignment: .topTrailing) {
            if isActive {
                Image(systemName: "sparkle")
                    .foregroundStyle(MynaTheme.mint)
                    .padding(10)
                    .symbolEffect(.pulse)
            }
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        switch state {
        case .notInstalled:
            actionButton("Download to iPhone", icon: "arrow.down.circle.fill", gradient: true) {
                modelManager.downloadAndLoad(model)
            }

        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: fraction)
                    .tint(MynaTheme.cyan)
                Text("Summoning weights… \(Int(fraction * 100))%")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(MynaTheme.cyan)
            }

        case .loading:
            HStack(spacing: 8) {
                ProgressView().tint(MynaTheme.gold)
                Text("Waking the model…")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(MynaTheme.gold)
            }

        case .installed, .ready:
            HStack(spacing: 10) {
                if isActive {
                    GlowChip(text: "Active Scribe", icon: "checkmark.circle.fill", tint: MynaTheme.mint)
                } else {
                    actionButton("Activate", icon: "bolt.fill", gradient: false) {
                        modelManager.downloadAndLoad(model)
                    }
                }
                Spacer()
                if model.backend == .mlx {
                    Button(role: .destructive) {
                        modelManager.delete(model)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13))
                            .foregroundStyle(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(model.backend == .appleFoundation ? MynaTheme.gold : .red.opacity(0.9))
                    .lineLimit(3)
                actionButton(model.backend == .appleFoundation ? "Check Again" : "Retry", icon: "arrow.clockwise", gradient: false) {
                    modelManager.downloadAndLoad(model)
                }
            }
        }
    }

    private func actionButton(_ title: String, icon: String, gradient: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(MynaTheme.display(13, weight: .semibold))
                .foregroundStyle(gradient ? MynaTheme.void : MynaTheme.cyan)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background {
                    if gradient {
                        Capsule().fill(MynaTheme.auroraGradient)
                    } else {
                        Capsule().strokeBorder(MynaTheme.cyan.opacity(0.6), lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private func badgeIcon(_ badge: CatalogModel.Badge) -> String {
        switch badge {
        case .recommended: return "crown.fill"
        case .fastest: return "hare.fill"
        case .maxQuality: return "brain.fill"
        case .mostPowerful: return "bolt.horizontal.fill"
        case .builtIn: return "apple.logo"
        }
    }

    private func badgeTint(_ badge: CatalogModel.Badge) -> Color {
        switch badge {
        case .recommended: return MynaTheme.gold
        case .fastest: return MynaTheme.mint
        case .maxQuality: return MynaTheme.magenta
        case .mostPowerful: return MynaTheme.cyan
        case .builtIn: return MynaTheme.mint
        }
    }
}
