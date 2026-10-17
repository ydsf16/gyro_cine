import SwiftUI
import UIKit

enum RulerMapping: Equatable {
    case linear, logarithmic
    func value(at fraction: Double, in range: ClosedRange<Double>) -> Double {
        let fraction = min(max(fraction, 0), 1)
        if self == .logarithmic, range.lowerBound > 0 {
            return exp(log(range.lowerBound) + fraction * log(range.upperBound / range.lowerBound))
        }
        return range.lowerBound + fraction * (range.upperBound - range.lowerBound)
    }
    func fraction(for value: Double, in range: ClosedRange<Double>) -> Double {
        if self == .logarithmic, range.lowerBound > 0 {
            return log(max(value, range.lowerBound) / range.lowerBound) /
                max(log(range.upperBound / range.lowerBound), 0.000001)
        }
        return (value - range.lowerBound) / max(range.upperBound - range.lowerBound, 0.000001)
    }
}

enum ControlStops {
    static let shutter: [Double] = [8000, 6400, 5000, 4000, 3200, 2500, 2000, 1600, 1250, 1000, 800, 640, 500, 400, 320, 250, 200, 160, 125, 120, 100, 80, 60, 50, 48, 40, 30, 25, 24, 20, 15, 10, 8, 6, 5, 4, 3, 2, 1].map { 1 / Double($0) }
    static let iso: [Double] = [25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800, 16000, 20000, 25600, 32000, 40000, 51200, 64000, 80000, 102400]
    static let angle: [Double] = [1, 2, 5, 11.25, 22.5, 45, 72, 90, 120, 144, 172.8, 180, 216, 270, 360]
    static func legal(_ values: [Double], range: ClosedRange<Double>) -> [Double] {
        Array(Set(values.filter { range.contains($0) } + [range.lowerBound, range.upperBound])).sorted()
    }
    static func snap(_ value: Double, values: [Double], range: ClosedRange<Double>, mapping: RulerMapping) -> Double {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        guard !values.isEmpty else { return clamped }
        let position = mapping.fraction(for: clamped, in: range)
        return legal(values, range: range).min {
            abs(mapping.fraction(for: $0, in: range) - position) < abs(mapping.fraction(for: $1, in: range) - position)
        } ?? clamped
    }
}

/// A fixed blue indicator over a scrollable scale. The visible ticks move with the user's finger.
struct MovingRuler: UIViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var value: Double
    let range: ClosedRange<Double>
    var mapping: RulerMapping = .linear
    var majorValues: [Double] = []
    var snapValues: [Double] = []
    var haptics = false
    var onInteractionBegan: () -> Void = {}
    let format: (Double) -> String
    let onChange: (Double, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> RulerContainer {
        let view = RulerContainer()
        context.coordinator.attachFeedback(to: view)
        view.scrollView.delegate = context.coordinator
        view.onAccessibilityAdjust = { [weak coordinator = context.coordinator] direction in
            coordinator?.adjustAccessibility(direction)
        }
        return view
    }
    func updateUIView(_ view: RulerContainer, context: Context) {
        context.coordinator.parent = self
        view.configure(value: value, range: range, mapping: mapping,
                       majorValues: majorValues, format: format, enabled: isEnabled)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: MovingRuler
        private var feedback: UISelectionFeedbackGenerator?
        private var lastTick: Double?
        private var lastFeedback = 0.0
        private var updating = false
        init(_ parent: MovingRuler) { self.parent = parent }
        func attachFeedback(to view: UIView) {
            feedback = UISelectionFeedbackGenerator(view: view)
        }
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            parent.onInteractionBegan()
            lastTick = tick(for: parent.value)
            if parent.haptics { feedback?.prepare() }
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) { report(scrollView, finished: false) }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { report(scrollView, finished: true) }
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { report(scrollView, finished: true) }
        func adjustAccessibility(_ direction: Double) {
            guard parent.isEnabled else { return }
            parent.onInteractionBegan()
            lastTick = tick(for: parent.value)
            if parent.haptics { feedback?.prepare() }
            let values = parent.snapValues.isEmpty ? (0...100).map {
                parent.mapping.value(at: Double($0) / 100, in: parent.range)
            } : ControlStops.legal(parent.snapValues, range: parent.range)
            let next = direction > 0 ? values.first { $0 > parent.value + 1e-9 } : values.last { $0 < parent.value - 1e-9 }
            if let next { send(next, finished: true) }
        }
        private func tick(for value: Double) -> Double {
            parent.snapValues.isEmpty ? (parent.mapping.fraction(for: value, in: parent.range) * 100).rounded() : value
        }
        private func send(_ value: Double, finished: Bool) {
            let tick = tick(for: value)
            let now = CACurrentMediaTime()
            if parent.haptics, let previous = lastTick, previous != tick, now - lastFeedback > 0.035 {
                feedback?.selectionChanged(); feedback?.prepare(); lastFeedback = now
            }
            lastTick = tick
            if parent.value != value || finished {
                parent.value = value
                parent.onChange(value, finished)
            }
        }
        private func report(_ scrollView: UIScrollView, finished: Bool) {
            guard !updating, parent.isEnabled, scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating || finished else { return }
            let step = (scrollView.contentOffset.x + scrollView.bounds.width / 2 - RulerContainer.labelInset) / RulerContainer.spacing
            let fraction = min(max(Double(step) / Double(RulerContainer.steps), 0), 1)
            let value = ControlStops.snap(parent.mapping.value(at: fraction, in: parent.range),
                values: parent.snapValues, range: parent.range, mapping: parent.mapping)
            send(value, finished: finished)
            if finished, !parent.snapValues.isEmpty {
                updating = true
                let offset = RulerContainer.labelInset + CGFloat(parent.mapping.fraction(for: value, in: parent.range)) * CGFloat(RulerContainer.steps) * RulerContainer.spacing - scrollView.bounds.width / 2
                scrollView.setContentOffset(CGPoint(x: offset, y: 0), animated: false)
                updating = false
            }
        }
    }
}

final class RulerContainer: UIView {
    static let steps = 100
    static let spacing: CGFloat = 12
    static let labelInset: CGFloat = 32
    let scrollView = UIScrollView()
    var onAccessibilityAdjust: ((Double) -> Void)?
    private let ticks = RulerTicksView()
    private let marker = UIView()
    private var targetValue = 0.0
    private var currentRange: ClosedRange<Double> = 0...1
    private var mapping: RulerMapping = .linear
    private var hasPositioned = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.decelerationRate = .fast
        scrollView.addSubview(ticks)
        addSubview(scrollView)
        marker.backgroundColor = UIColor(red: 0.08, green: 0.62, blue: 1, alpha: 1)
        marker.layer.cornerRadius = 1.5
        marker.isUserInteractionEnabled = false
        addSubview(marker)
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    func configure(value: Double, range: ClosedRange<Double>, mapping: RulerMapping,
                   majorValues: [Double], format: @escaping (Double) -> String, enabled: Bool) {
        let rangeChanged = currentRange != range || self.mapping != mapping
        targetValue = min(max(value, range.lowerBound), range.upperBound)
        currentRange = range
        self.mapping = mapping
        ticks.range = range
        ticks.mapping = mapping
        ticks.majorValues = majorValues
        ticks.format = format
        ticks.setNeedsDisplay()
        scrollView.isScrollEnabled = enabled
        scrollView.alpha = enabled ? 1 : 0.6
        accessibilityValue = format(targetValue)
        if rangeChanged { hasPositioned = false }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        let contentWidth = CGFloat(Self.steps) * Self.spacing + 2 * Self.labelInset + 1
        ticks.frame = CGRect(x: 0, y: 0, width: contentWidth, height: bounds.height)
        scrollView.contentSize = ticks.bounds.size
        scrollView.contentInset = UIEdgeInsets(top: 0, left: bounds.width / 2, bottom: 0, right: bounds.width / 2)
        marker.frame = CGRect(x: bounds.midX - 1.5, y: 0, width: 3, height: 32)
        guard bounds.width > 0 else { return }
        if !scrollView.isDragging && !scrollView.isDecelerating {
            let fraction = mapping.fraction(for: targetValue, in: currentRange)
            let offset = Self.labelInset + CGFloat(fraction) * CGFloat(Self.steps) * Self.spacing - bounds.width / 2
            if !hasPositioned || abs(scrollView.contentOffset.x - offset) > 0.5 {
                scrollView.setContentOffset(CGPoint(x: offset, y: 0), animated: false)
                hasPositioned = true
            }
        }
    }

    override func accessibilityIncrement() {
        adjustAccessibility(by: 1)
    }
    override func accessibilityDecrement() {
        adjustAccessibility(by: -1)
    }
    private func adjustAccessibility(by direction: Double) {
        onAccessibilityAdjust?(direction)
    }
}

private final class RulerTicksView: UIView {
    var range: ClosedRange<Double> = 0...1
    var mapping: RulerMapping = .linear
    var majorValues: [Double] = []
    var format: (Double) -> String = { String(format: "%.2f", $0) }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        for step in 0...RulerContainer.steps {
            let x = RulerContainer.labelInset + CGFloat(step) * RulerContainer.spacing + 0.5
            let major = step.isMultiple(of: 5)
            context.setStrokeColor(UIColor.white.withAlphaComponent(major ? 0.8 : 0.38).cgColor)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: x, y: 6))
            context.addLine(to: CGPoint(x: x, y: major ? 25 : 17))
            context.strokePath()
            if majorValues.isEmpty && step.isMultiple(of: 10) {
                let value = mapping.value(at: Double(step) / Double(RulerContainer.steps), in: range)
                let label = format(value) as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 10),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.72)
                ]
                let size = label.size(withAttributes: attributes)
                label.draw(at: CGPoint(x: x - size.width / 2, y: 37), withAttributes: attributes)
            }
        }
        if !majorValues.isEmpty {
            var lastLabelEnd: CGFloat = -100
            for value in Set(majorValues).sorted() where range.contains(value) {
                let x = RulerContainer.labelInset + CGFloat(mapping.fraction(for: value, in: range)) *
                    CGFloat(RulerContainer.steps) * RulerContainer.spacing + 0.5
                context.setStrokeColor(UIColor.white.cgColor)
                context.setLineWidth(1.5)
                context.move(to: CGPoint(x: x, y: 3))
                context.addLine(to: CGPoint(x: x, y: 30))
                context.strokePath()
                let label = format(value) as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.85)
                ]
                let size = label.size(withAttributes: attributes)
                let start = x - size.width / 2
                if start >= lastLabelEnd + 8 {
                    label.draw(at: CGPoint(x: start, y: 37), withAttributes: attributes)
                    lastLabelEnd = start + size.width
                }
            }
        }
    }
}
