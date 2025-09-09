//
//  LoadingLineView.swift
//  UsefulMacApp
//
//  A clean, modern animated loading line used during AI thinking.
//

import SwiftUI

struct LoadingLineView: View {
	@State private var phase: CGFloat = 0.0
	var height: CGFloat = 3
	var body: some View {
		GeometryReader { geo in
			let trackWidth = max(1, geo.size.width)
			let baseWidth = trackWidth * 0.95 * 0.65
			let taperFactor: CGFloat = phase > 0.85 ? max(0.12, 1.0 - (phase - 0.85) / 0.15) : 1.0
			let easeInFactor: CGFloat = phase < 0.15 ? max(0.15, phase / 0.15) : 1.0
			let segmentLengthBoost: CGFloat = 1.20
			let segWidth = baseWidth * segmentLengthBoost * taperFactor * easeInFactor
			let offsetX = (trackWidth - segWidth) * phase
			ZStack(alignment: .leading) {
				Capsule()
					.fill(Color.white.opacity(0.16))
					.frame(height: height)
				Capsule()
					.fill(
						LinearGradient(
							gradient: Gradient(colors: [
								Color.white.opacity(0.0),
								Color.white,
								Color.white.opacity(0.0)
							]),
						startPoint: .leading,
						endPoint: .trailing
						)
					)
					.frame(width: segWidth, height: height)
					.offset(x: offsetX)
			}
			.clipped()
			.onAppear {
				withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) {
					phase = 1.0
				}
			}
			.onChange(of: geo.size.width) { _ in
				phase = 0.0
				withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) {
					phase = 1.0
				}
			}
		}
		.frame(height: height)
	}
}

struct LoadingDotsView: View {
    private let dotCount = 3
    private let dotSize: CGFloat = 3
    private let rise: CGFloat = 3
    private let period: Double = 1.2

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = (t.truncatingRemainder(dividingBy: period)) / period // 0..1
            HStack(spacing: 5) {
                ForEach(0..<dotCount, id: \.self) { idx in
                    Circle()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: dotSize, height: dotSize)
                        .offset(y: yOffset(for: idx, phase: phase))
                }
            }
        }
    }

    private func yOffset(for index: Int, phase: Double) -> CGFloat {
        let shift = Double(index) / Double(dotCount)
        let angle = 2.0 * Double.pi * (phase + shift)
        return CGFloat(-sin(angle)) * rise
    }
}


