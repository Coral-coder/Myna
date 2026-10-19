import SwiftUI
import UIKit

/// Backstage card: switch each on-device context source on or off, and keep
/// the list of named places.
struct ContextCard: View {
    @EnvironmentObject private var hub: ContextHub
    @State private var busy: ContextHub.Source?
    @State private var denied: ContextHub.Source?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(icon: "sparkle.magnifyingglass", title: "On-Device Context", tint: MynaTheme.gold)
            Text("Let Myna use more of what this iPhone knows. Each source is off until you turn it on, is read only on this iPhone, and can be turned off any time.")
                .contextCaption()

            sourceToggle(.location, title: "Places", detail: "Note where each conversation happened, using places you've named below.")
            if hub.isEnabled(.location) {
                PlacesEditor(location: hub.location)
                Toggle(isOn: Binding(get: { hub.allowsGeocoding }, set: { hub.allowsGeocoding = $0 })) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Name other places with Apple Maps").contextLabel()
                        Text("Off by default. When on, coordinates of unnamed places are sent to Apple to look up a name like “Blue Bottle, Oakland”.").contextCaption()
                    }
                }
                .tint(MynaTheme.gold)
                .padding(.leading, 12)
            }
            sourceToggle(.contacts, title: "Contacts", detail: "Spell names right and know who people are. Reads names, company and job title only.")
            if HealthContext.isAvailable {
                sourceToggle(.health, title: "Health", detail: "Answer questions about your sleep, steps, resting heart rate and workouts. Read-only, read only when you ask.")
            }
            sourceToggle(.photos, title: "Photos", detail: "Attach photos taken during a conversation and read whiteboards and slides into the note.")

            if let denied {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(MynaTheme.gold)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("iOS didn't allow \(name(of: denied)). You can change that in Settings.").contextCaption()
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .tint(MynaTheme.gold)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(glow: MynaTheme.gold)
    }

    private func sourceToggle(_ source: ContextHub.Source, title: String, detail: String) -> some View {
        Toggle(isOn: Binding(
            get: { hub.isEnabled(source) },
            set: { on in
                busy = source
                Task {
                    let enabled = await hub.setEnabled(source, on)
                    denied = on && !enabled ? source : nil
                    busy = nil
                }
            }
        )) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).contextLabel()
                    if busy == source { ProgressView().controlSize(.mini).tint(MynaTheme.gold) }
                }
                Text(detail).contextCaption()
            }
        }
        .tint(MynaTheme.gold)
        .disabled(busy != nil)
    }

    private func name(of source: ContextHub.Source) -> String {
        switch source {
        case .location: return "location access"
        case .contacts: return "contacts access"
        case .health: return "Health access"
        case .photos: return "photo library access"
        }
    }
}

/// Named places, saved to the Keychain.
private struct PlacesEditor: View {
    @ObservedObject var location: LocationContext
    @State private var newName = ""
    @State private var saving = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(location.places) { place in
                HStack {
                    Image(systemName: "mappin.circle.fill").foregroundStyle(MynaTheme.gold)
                    Text(place.name).contextLabel()
                    Spacer()
                    Button {
                        location.removePlace(place)
                    } label: {
                        Image(systemName: "trash").foregroundStyle(.white.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 8) {
                TextField("Name this spot, e.g. Home", text: $newName)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.06)))
                Button {
                    saving = true
                    Task {
                        failed = !(await location.saveCurrentPlace(named: newName))
                        if !failed { newName = "" }
                        saving = false
                    }
                } label: {
                    if saving {
                        ProgressView().controlSize(.small).tint(MynaTheme.gold)
                    } else {
                        Text("Save here").font(.system(size: 13, weight: .semibold, design: .rounded))
                    }
                }
                .tint(MynaTheme.gold)
                .disabled(saving || newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if failed {
                Text("Couldn't get a location fix. Try again in a moment.").contextCaption()
            }
        }
        .padding(.leading, 12)
    }
}

private extension Text {
    func contextLabel() -> Text {
        font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundColor(.white.opacity(0.9))
    }

    func contextCaption() -> Text {
        font(.system(size: 12, design: .rounded))
            .foregroundColor(.white.opacity(0.5))
    }
}
