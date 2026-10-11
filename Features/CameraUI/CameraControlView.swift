import SwiftUI
import UIKit

enum CameraControl: String, CaseIterable, Identifiable {
    case resolution = "分辨率", fps = "帧率", shutter = "最长曝光", whiteBalance = "白平衡"
    var id: String { rawValue }
}

struct CameraControlView: View {
    @ObservedObject var model: RecorderViewModel
    let selection: CameraControl
    var portrait = false
    var close: () -> Void
    @State private var centered: Int?
    @State private var dragging = false
    @State private var autoClose: Task<Void, Never>?
    static func portraitHeight(for selection: CameraControl) -> CGFloat { 144 }

    private var labels: [String] {
        switch selection {
        case .resolution: return model.resolutionOptions.map(\.resolutionLabel)
        case .fps: return model.frameRateOptions.map(String.init)
        case .shutter: return model.supportedShutters.map(\.label)
        case .whiteBalance: return ["自动"] + stride(from: 2000, through: 10000, by: 100).map { "\($0)K" }
        }
    }
    private var current: Int {
        switch selection {
        case .resolution: return model.resolutionOptions.firstIndex { "\($0.width)x\($0.height)" == model.resolutionKey } ?? 0
        case .fps: return model.frameRateOptions.firstIndex(of: model.selectedMode?.fps ?? 30) ?? 0
        case .shutter: return model.supportedShutters.firstIndex(of: model.shutter) ?? 0
        case .whiteBalance: return model.controls.automaticWhiteBalance ? 0 : min(81, max(1, Int((model.controls.temperature - 2000) / 100) + 1))
        }
    }
    private func commit(_ index: Int) {
        guard labels.indices.contains(index) else { return }
        switch selection {
        case .resolution:
            let mode = model.resolutionOptions[index]
            model.selectResolution("\(mode.width)x\(mode.height)")
        case .fps: model.selectFrameRate(model.frameRateOptions[index])
        case .shutter: model.setExposureLimit(model.supportedShutters[index])
        case .whiteBalance:
            if index == 0 { model.setAutomaticWhiteBalance(true) }
            else { model.applyControls { $0.automaticWhiteBalance = false; $0.temperature = Float(2000 + (index - 1) * 100); $0.tint = 0 } }
        }
        autoClose?.cancel()
        autoClose = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, !dragging else { return }
            close()
        }
    }
    var body: some View {
        VStack(spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selection.rawValue).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                    Text(labels.indices.contains(centered ?? current) ? labels[centered ?? current] : "—")
                        .font(.system(size: portrait ? 19 : 15, weight: .semibold, design: .rounded))
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.55)
                }
                Spacer()
                Button { autoClose?.cancel(); close() } label: { Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).frame(width: 32, height: 32)
                    .background(.white.opacity(0.12), in: Circle()) }
                    .accessibilityLabel("关闭参数").accessibilityIdentifier("closeCameraControl")
            }.padding(.horizontal, 14).padding(.top, 7)
            GeometryReader { geometry in
                ScrollView(portrait ? .horizontal : .vertical) {
                    if portrait {
                        LazyHStack(spacing: 0) { items.frame(width: 54, height: geometry.size.height) }.scrollTargetLayout()
                    } else {
                        LazyVStack(spacing: 0) { items.frame(height: 38) }.scrollTargetLayout()
                    }
                }
                .contentMargins(portrait ? .horizontal : .vertical, max(0, (portrait ? geometry.size.width - 54 : geometry.size.height - 38) / 2), for: .scrollContent)
                .scrollIndicators(.hidden).scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $centered, anchor: .center)
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting { dragging = true; autoClose?.cancel() }
                    if phase == .idle && dragging {
                        dragging = false
                        if let centered { commit(centered); UISelectionFeedbackGenerator().selectionChanged() }
                    }
                }
                .overlay(alignment: portrait ? .bottom : .trailing) {
                    Capsule().fill(RecorderTheme.accent)
                        .frame(width: portrait ? 3 : 20, height: portrait ? 19 : 3)
                        .allowsHitTesting(false)
                }
                .accessibilityIdentifier("cameraParameterRuler")
            }.padding(.bottom, 10)
        }
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.13), lineWidth: 0.5))
        .task(id: selection) { centered = current }
        .onChange(of: current) { _, value in if !dragging { centered = value } }
        .onDisappear { autoClose?.cancel() }
        .accessibilityElement(children: .contain).accessibilityIdentifier("cameraControlPanel_" + selection.id)
    }
    private var items: some View {
        ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
            Button { centered = index; commit(index) } label: {
                Group {
                    if portrait {
                        VStack(spacing: 5) {
                            Capsule().fill(index == (centered ?? current) ? RecorderTheme.accent : .white.opacity(index.isMultiple(of: 5) ? 0.8 : 0.4))
                                .frame(width: 2, height: index == (centered ?? current) ? 27 : index.isMultiple(of: 5) ? 21 : 13)
                            if labels.count <= 8 || index == (centered ?? current) || index.isMultiple(of: 10) {
                                Text(label).font(.system(size: 9, weight: .medium)).lineLimit(1).minimumScaleFactor(0.55)
                            }
                        }
                    } else {
                        HStack(spacing: 5) {
                            Capsule().fill(index == (centered ?? current) ? RecorderTheme.accent : .white.opacity(index.isMultiple(of: 5) ? 0.8 : 0.4))
                                .frame(width: index == (centered ?? current) ? 25 : index.isMultiple(of: 5) ? 18 : 11, height: 2)
                            if labels.count <= 8 || index == (centered ?? current) || index.isMultiple(of: 10) {
                                Text(label).font(.system(size: 9, weight: .medium)).lineLimit(1).minimumScaleFactor(0.55)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(index == (centered ?? current) ? RecorderTheme.accent : .white.opacity(0.7))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(label).id(index)
        }
    }
}
