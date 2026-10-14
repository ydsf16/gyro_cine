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

/// A fixed blue indicator over a scrollable scale. The visible ticks move with the user's finger.
struct MovingRuler: UIViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var value: Double
    let range: ClosedRange<Double>
    var mapping: RulerMapping = .linear
    var majorValues: [Double] = []
    let format: (Double) -> String
    let onChange: (Double, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> RulerContainer {
        let view = RulerContainer()
        view.scrollView.delegate = context.coordinator
        return view
    }
    func updateUIView(_ view: RulerContainer, context: Context) {
        context.coordinator.parent = self
        view.configure(value: value, range: range, mapping: mapping,
                       majorValues: majorValues, format: format, enabled: isEnabled)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: MovingRuler
        init(_ parent: MovingRuler) { self.parent = parent }
        func scrollViewDidScroll(_ scrollView: UIScrollView) { report(scrollView, finished: false) }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { report(scrollView, finished: true) }
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { report(scrollView, finished: true) }
        private func report(_ scrollView: UIScrollView, finished: Bool) {
            guard parent.isEnabled, scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating || finished else { return }
            let step = (scrollView.contentOffset.x + scrollView.bounds.width / 2 - RulerContainer.labelInset) / RulerContainer.spacing
            let fraction = min(max(Double(step) / Double(RulerContainer.steps), 0), 1)
            let value = parent.mapping.value(at: fraction, in: parent.range)
            parent.value = value
            parent.onChange(value, finished)
        }
    }
}

final class RulerContainer: UIView {
    static let steps = 100
    static let spacing: CGFloat = 12
    static let labelInset: CGFloat = 32
    let scrollView = UIScrollView()
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
        let fraction = mapping.fraction(for: targetValue, in: currentRange) + direction / Double(Self.steps)
        targetValue = mapping.value(at: fraction, in: currentRange)
        setNeedsLayout()
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
