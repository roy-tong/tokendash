import SwiftUI
import Charts

/// Trailing window for the pulse chart's smoothed rate curve (seconds). Each
/// point on the curve = Σ token deltas in the past `pulseSmoothWindow` ÷ window.
private let pulseSmoothWindow: TimeInterval = 30

/// Feature flag: the Pulse tab + its 10s rate-sampling are hidden for the
/// energy-optimization release (sampling was a top CPU draw). Flip to true to
/// re-enable both the UI tab and the sampler.
private let pulseEnabled = false

struct HourlyChartView: View {
    // TODO(Task 9): temporary compile shim — bucket.hour accessors were
    // replaced by hour(of:) when HourBucket became TimeBucket. The view is
    // rewritten wholesale in Task 9; do not extend this shim.
    let data: [TimeBucket]
    let pulseSamples: [TokenPulseSample]
    @State private var selectedMode: ChartMode = .today
    @State private var hoveredHour: Int?
    @Namespace private var selectorAnimation

    private enum ChartMode: String, CaseIterable, Identifiable {
        case today = "Today"
        case pulse = "Pulse"

        var id: Self { self }
    }

    private var currentHour: Int {
        let cal = Calendar.current
        return cal.component(.hour, from: Date())
    }

    /// Shim: hour-of-day of a bucket start (replaces the old HourBucket.hour).
    private func hour(of bucket: TimeBucket) -> Int {
        Calendar.current.component(.hour, from: bucket.start)
    }

    private var elapsedData: [TimeBucket] {
        data.filter { hour(of: $0) <= currentHour }
    }

    private var hoveredBucket: TimeBucket? {
        guard let hoveredHour else { return nil }
        return elapsedData.first { hour(of: $0) == hoveredHour }
    }

    private var yAxisUpperBound: Int {
        let maximum = elapsedData.map(\.tokens).max() ?? 0
        return max(1, Int(ceil(Double(maximum) * 1.15)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 10)

            if pulseEnabled && selectedMode == .pulse {
                TokenPulseChartView(samples: pulseSamples)
            } else if data.allSatisfy({ $0.tokens == 0 }) {
                emptyChart
            } else {
                chartArea
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            if pulseEnabled && selectedMode == .pulse {
                HStack(spacing: 5) {
                    Circle()
                        .fill(pulseMetrics.isStageActive ? Color.accentGreen : Color.tertiaryLabel)
                        .frame(width: 6, height: 6)
                    Text(pulseMetrics.isStageActive ? "STAGE AVG" : "IDLE")
                        .font(.system(size: 10, weight: .semibold))
                    Text("\(formatTokenRate(pulseMetrics.isStageActive ? pulseMetrics.stageAverageRate : 0))/s")
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Color.secondaryLabel)
                }
                .foregroundStyle(pulseMetrics.isStageActive ? Color.accentGreen : Color.secondaryLabel)
            } else {
                Text("HOURLY")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(Color.sectionTitleColor)
            }

            Spacer()

            if pulseEnabled {
                modeTabs
            }
        }
    }

    private var modeTabs: some View {
        HStack(spacing: 2) {
            ForEach(ChartMode.allCases) { mode in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        selectedMode = mode
                    }
                } label: {
                    Text(mode.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(selectedMode == mode ? Color.white : Color.secondaryLabel)
                        .padding(.horizontal, 11)
                        .frame(height: 24)
                        .background {
                            if selectedMode == mode {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.accentGreen)
                                    .matchedGeometryEffect(
                                        id: "hour-mode-selection",
                                        in: selectorAnimation
                                    )
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedMode == mode ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .fixedSize()
        .animation(.easeInOut(duration: 0.12), value: selectedMode)
    }

    private var pulseMetrics: TokenPulseMetrics {
        TokenPulseMetrics(samples: pulseSamples)
    }

    private func formatTokenRate(_ rate: Double) -> String {
        let rounded = max(0, Int(rate.rounded()))
        return rounded < 1_000 ? "\(rounded)" : formatTokens(rounded)
    }

    // MARK: - Area chart

    private var chartArea: some View {
        Chart {
            ForEach(elapsedData) { bucket in
                // Area fill
                AreaMark(
                    x: .value("Hour", hour(of: bucket)),
                    y: .value("Tokens", bucket.tokens)
                )
                .foregroundStyle(
                    .linearGradient(
                        colors: [Color.accentGreen.opacity(0.3), Color.accentGreen.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)

                // Line
                LineMark(
                    x: .value("Hour", hour(of: bucket)),
                    y: .value("Tokens", bucket.tokens)
                )
                .foregroundStyle(Color.accentGreen)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.catmullRom)

                // Current-hour dot with glow (uses Chart's own coordinate system)
                if hour(of: bucket) == currentHour {
                    PointMark(
                        x: .value("Hour", hour(of: bucket)),
                        y: .value("Tokens", bucket.tokens)
                    )
                    .foregroundStyle(Color.accentGreen.opacity(0.12))
                    .symbolSize(80)

                    PointMark(
                        x: .value("Hour", hour(of: bucket)),
                        y: .value("Tokens", bucket.tokens)
                    )
                    .foregroundStyle(Color.accentGreen)
                    .symbolSize(20)
                }
            }

            if let hoveredBucket {
                RuleMark(x: .value("Selected hour", hour(of: hoveredBucket)))
                    .foregroundStyle(.secondary.opacity(0.25))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))

                PointMark(
                    x: .value("Selected hour", hour(of: hoveredBucket)),
                    y: .value("Selected tokens", hoveredBucket.tokens)
                )
                .foregroundStyle(Color.accentGreen)
                .symbolSize(34)
                .annotation(position: .top, spacing: 6) {
                    hoverLabel(for: hoveredBucket)
                }
            }
        }
        .chartXScale(domain: 0...23)
        .chartYScale(domain: 0...yAxisUpperBound)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.primary.opacity(0.05))
                AxisValueLabel {
                    if let tokens = value.as(Int.self) {
                        Text(formatTokens(tokens))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color.tertiaryLabel)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: [0, 3, 6, 9, 12, 15, 18, 21]) { value in
                if let hour = value.as(Int.self) {
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        .foregroundStyle(.primary.opacity(0.03))
                    AxisValueLabel {
                        Text("\(hour)")
                            .font(.system(size: 9, weight: hour == currentHour ? .semibold : .medium))
                            .foregroundStyle(timeLabelColor(for: hour))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            updateHoveredHour(at: location, proxy: proxy, geometry: geometry)
                        case .ended:
                            hoveredHour = nil
                        }
                    }
            }
        }
        .frame(height: 110)
    }

    private func timeLabelColor(for hour: Int) -> Color {
        if hour == currentHour { return Color.accentGreen }
        if hour > currentHour { return Color.futureLabelColor }
        return Color.tertiaryLabel
    }

    private func updateHoveredHour(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        guard let plotFrame = proxy.plotFrame else {
            hoveredHour = nil
            return
        }

        let frame = geometry[plotFrame]
        guard frame.contains(location) else {
            hoveredHour = nil
            return
        }

        let plotX = location.x - frame.minX
        guard let hour: Double = proxy.value(atX: plotX) else {
            hoveredHour = nil
            return
        }

        let nearestHour = Int(hour.rounded())
        hoveredHour = elapsedData.contains { self.hour(of: $0) == nearestHour } ? nearestHour : nil
    }

    private func hoverLabel(for bucket: TimeBucket) -> some View {
        VStack(spacing: 1) {
            Text(String(format: "%02d:00", hour(of: bucket)))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text("\(formatTokens(bucket.tokens)) tokens")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(.primary.opacity(0.08), lineWidth: 0.5)
        }
    }

    // MARK: - Empty state

    private var emptyChart: some View {
        VStack(spacing: 6) {
            Text("No usage yet")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.5))
            Text("Start a session to see your hourly breakdown.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

private struct TokenPulseChartView: View {
    let samples: [TokenPulseSample]
    @State private var hoverLocation: CGPoint?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                drawPulse(layout: PulseLayout(samples: samples, size: size), context: &context, phase: phase)
            }
        }
        .frame(height: 110)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                seriesLabel("Input", color: .accentGreen)
                seriesLabel("Output", color: .blue)
            }
            .padding(.top, 1)
            .padding(.trailing, 2)
        }
        .overlay(alignment: .bottomLeading) {
            Text("30m ago")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.tertiaryLabel)
                .padding(.bottom, 1)
                .padding(.leading, 2)
        }
        .overlay(alignment: .bottomTrailing) {
            Text("now")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.tertiaryLabel)
                .padding(.bottom, 1)
                .padding(.trailing, 2)
        }
        // Hover hit-testing covers the whole plot so the tooltip can follow the
        // cursor anywhere along the 30-minute window.
        .overlay {
            Color.clear
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoverLocation = location
                    case .ended:
                        hoverLocation = nil
                    }
                }
        }
        // The tooltip floats above the cursor and must never steal hover events
        // from the clear overlay below, otherwise it flickers on/off.
        .overlay {
            GeometryReader { geo in
                if let hoverLocation {
                    let layout = PulseLayout(samples: samples, size: geo.size)
                    if let sample = layout.sample(atX: hoverLocation.x) {
                        let rate = layout.smoothedRate(for: sample)
                            ?? (input: sample.inputTokensPerSecond, output: sample.outputTokensPerSecond)
                        pulseTooltip(timestamp: sample.timestamp, input: rate.input, output: rate.output)
                            .position(
                                x: min(max(hoverLocation.x, 64), max(64, geo.size.width - 64)),
                                y: 16
                            )
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func seriesLabel(_ label: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(label)
                .foregroundStyle(Color.secondaryLabel)
        }
        .font(.system(size: 9, weight: .medium))
    }

    private func formatRate(_ rate: Double) -> String {
        let value = max(0, Int(rate.rounded()))
        return value < 1_000 ? "\(value)" : formatTokens(value)
    }

    private func pulseTimeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func pulseTooltip(timestamp: Date, input: Double, output: Double) -> some View {
        VStack(spacing: 1) {
            Text(pulseTimeString(timestamp))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text("↑ \(formatRate(input))/s")
                    .foregroundStyle(Color.accentGreen)
                Text("↓ \(formatRate(output))/s")
                    .foregroundStyle(Color.blue)
            }
            .font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(.primary.opacity(0.08), lineWidth: 0.5)
        }
    }

    private func drawPulse(layout: PulseLayout, context: inout GraphicsContext, phase: TimeInterval) {
        let size = layout.size

        context.stroke(
            Path { path in
                path.move(to: CGPoint(x: 0, y: layout.baselineY))
                path.addLine(to: CGPoint(x: size.width, y: layout.baselineY))
            },
            with: .color(Color.primary.opacity(0.10)),
            lineWidth: 0.5
        )

        guard !layout.samples.isEmpty else { return }

        let inputLine = smoothPath(through: layout.inputPoints)
        let outputLine = smoothPath(through: layout.outputPoints)

        var inputFill = inputLine
        if let first = layout.inputPoints.first, let last = layout.inputPoints.last {
            inputFill.addLine(to: CGPoint(x: last.x, y: layout.baselineY))
            inputFill.addLine(to: CGPoint(x: first.x, y: layout.baselineY))
            inputFill.closeSubpath()
        }

        var outputFill = outputLine
        if let first = layout.outputPoints.first, let last = layout.outputPoints.last {
            outputFill.addLine(to: CGPoint(x: last.x, y: layout.baselineY))
            outputFill.addLine(to: CGPoint(x: first.x, y: layout.baselineY))
            outputFill.closeSubpath()
        }

        context.fill(inputFill, with: .color(Color.accentGreen.opacity(0.45)))
        context.fill(outputFill, with: .color(Color.blue.opacity(0.45)))

        context.stroke(
            inputLine,
            with: .color(Color.accentGreen),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            outputLine,
            with: .color(Color.blue),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
        )

        let pulse = 0.5 + 0.5 * sin(phase * 3.2)
        let latestInput = layout.samples.last?.inputTokensPerSecond ?? 0
        let latestOutput = layout.samples.last?.outputTokensPerSecond ?? 0
        let activeEndPoint: CGPoint
        let activeColor: Color
        if latestOutput > latestInput {
            activeEndPoint = layout.outputPoints.last ?? CGPoint(x: size.width, y: layout.baselineY)
            activeColor = .blue
        } else {
            activeEndPoint = layout.inputPoints.last ?? CGPoint(x: size.width, y: layout.baselineY)
            activeColor = .accentGreen
        }
        context.fill(
            Path(ellipseIn: CGRect(
                x: activeEndPoint.x - 11 - CGFloat(pulse) * 3,
                y: activeEndPoint.y - 11 - CGFloat(pulse) * 3,
                width: 22 + CGFloat(pulse) * 6,
                height: 22 + CGFloat(pulse) * 6
            )),
            with: .color(activeColor.opacity(0.10))
        )
        context.fill(
            Path(ellipseIn: CGRect(
                x: activeEndPoint.x - 4.5,
                y: activeEndPoint.y - 4.5,
                width: 9,
                height: 9
            )),
            with: .color(activeColor)
        )
    }

    /// Smooth Catmull-Rom spline through the given points, rendered as a path of
    /// cubic Bézier segments. Tension 0.5 produces the gentle, continuous curve
    /// that the previous straight `addLine` joins were missing.
    private func smoothPath(through points: [CGPoint], tension: CGFloat = 0.5) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else { return path }
        if points.count == 2 {
            path.addLine(to: points[1])
            return path
        }
        let k = tension / 3
        for index in 0..<(points.count - 1) {
            let p0 = index == 0 ? points[0] : points[index - 1]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = index + 2 < points.count ? points[index + 2] : points[index + 1]
            let control1 = CGPoint(x: p1.x + (p2.x - p0.x) * k, y: p1.y + (p2.y - p0.y) * k)
            let control2 = CGPoint(x: p2.x - (p3.x - p1.x) * k, y: p2.y - (p3.y - p1.y) * k)
            path.addCurve(to: p2, control1: control1, control2: control2)
        }
        return path
    }
}

/// Pre-computed geometry for the pulse chart. The canvas renderer and the hover
/// hit-testing share one layout so a cursor position maps to exactly the sample
/// the eye sees on the curve.
private struct PulseLayout {
    let size: CGSize
    let topPadding: CGFloat = 8
    let bottomPadding: CGFloat = 22
    let baselineY: CGFloat
    let sharedPeakRate: Double
    let samples: [TokenPulseSample]
    let rates: [(input: Double, output: Double)]
    let inputPoints: [CGPoint]
    let outputPoints: [CGPoint]
    let windowStart: Date

    init(samples: [TokenPulseSample], size: CGSize) {
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        self.samples = sorted
        self.size = size
        // Input rises above the baseline, output drops below it — two mirrored
        // translucent bands sharing one midline.
        let chartHeight = max(1, size.height - topPadding - bottomPadding)
        baselineY = topPadding + chartHeight * 0.52
        let upperHeight = chartHeight * 0.44
        let lowerHeight = chartHeight * 0.40
        let now = sorted.last?.timestamp ?? Date()
        windowStart = now.addingTimeInterval(-30 * 60)

        // Smoothed trailing-window rates — kills the 0↔spike jitter from batched
        // JSONL writes by spreading each response's tokens across the window.
        let rates = pulseSmoothedRates(for: sorted, window: pulseSmoothWindow)
        self.rates = rates
        sharedPeakRate = max(
            rates.map(\.input).max() ?? 0,
            rates.map(\.output).max() ?? 0,
            1
        )

        var inputs: [CGPoint] = []
        var outputs: [CGPoint] = []
        for (index, sample) in sorted.enumerated() {
            let elapsed = sample.timestamp.timeIntervalSince(windowStart)
            let x = size.width * CGFloat(max(0, min(1, elapsed / (30 * 60))))
            let rate = rates[index]
            let normalizedInput = log1p(rate.input) / log1p(sharedPeakRate)
            let normalizedOutput = log1p(rate.output) / log1p(sharedPeakRate)
            inputs.append(CGPoint(x: x, y: baselineY - upperHeight * CGFloat(normalizedInput)))
            outputs.append(CGPoint(x: x, y: baselineY + lowerHeight * CGFloat(normalizedOutput)))
        }
        inputPoints = inputs
        outputPoints = outputs
    }

    /// Smoothed (input, output) rate for a given sample, for the hover tooltip.
    func smoothedRate(for sample: TokenPulseSample) -> (input: Double, output: Double)? {
        guard let index = samples.firstIndex(where: { $0.timestamp == sample.timestamp }),
              index < rates.count else { return nil }
        return rates[index]
    }

    /// Map a horizontal position (0…width) to the nearest sample in time.
    func sample(atX x: CGFloat) -> TokenPulseSample? {
        guard !samples.isEmpty, size.width > 0 else { return nil }
        let fraction = max(0, min(1, x / size.width))
        let target = windowStart.addingTimeInterval(fraction * 30 * 60)
        return samples.min {
            abs($0.timestamp.timeIntervalSince(target)) < abs($1.timestamp.timeIntervalSince(target))
        }
    }
}
