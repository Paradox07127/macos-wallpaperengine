import SwiftUI

/// The lyric rows under a Now Playing type block. Only this subview knows the lyric time base: word-level
/// highlighting needs finer ticks than the 1 Hz board clock, so it wraps itself — and only itself — in a 10fps
/// `TimelineView`, the same containment the audio-reactive layer uses for its 30fps canvas.
struct NowPlayingLyricsView: View {
    /// Where the playhead was at `date`, and whether it keeps running from
    /// there. Absent when the player reports no position at all.
    struct Playhead: Equatable {
        var position: Double
        var date: Date
        var advancing: Bool
    }

    let lines: [LyricLine]
    /// 1 or 3; the caller derives it from the tile size.
    let lineCount: Int
    let playhead: Playhead?
    let accent: Color
    let alignment: NowPlayingOptions.Alignment
    let fontSize: CGFloat
    /// The layer's text-brightness dial, applied over each row's own alpha.
    let brightness: Double
    /// Any line carries word tags, so the finer timeline is worth running.
    let wordTimed: Bool

    var body: some View {
        if wordTimed, let playhead, playhead.advancing {
            TimelineView(.animation(minimumInterval: 1.0 / 10.0, paused: false)) { timeline in
                rows(at: playhead.position + max(0, timeline.date.timeIntervalSince(playhead.date)))
            }
        } else if let playhead {
            // Line-level: the parent's 1 Hz tick already advances `date`.
            rows(at: playhead.position)
        } else {
            // No position from this player, so no timeline to follow: the
            // opening rows stand still rather than run on an invented clock.
            opening
        }
    }

    /// The first rows of the song, with the top one at full weight: used both
    /// before the first line starts and when the player reports no position.
    private var opening: some View {
        rows(slots: Array(lines.prefix(max(1, lineCount)).map { Optional($0) }), current: 0, at: nil)
    }

    private func rows(at time: Double) -> some View {
        let index = NowPlayingLyrics.activeIndex(lines: lines, at: time)
        guard let index else {
            return AnyView(opening)
        }
        if lineCount <= 1 {
            return AnyView(rows(slots: [lines[index]], current: 0, at: time))
        }
        let slots = [index - 1, index, index + 1].map { lines.indices.contains($0) ? lines[$0] : nil }
        return AnyView(rows(slots: slots, current: 1, at: time))
    }

    /// A fixed number of rows either way, so a missing neighbour does not
    /// change the tile's height mid-song.
    private func rows(slots: [LyricLine?], current: Int?, at time: Double?) -> some View {
        VStack(alignment: alignment.horizontal, spacing: fontSize * 0.28) {
            ForEach(Array(slots.enumerated()), id: \.offset) { offset, line in
                row(line, isCurrent: offset == current, at: time)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment.frame)
    }

    @ViewBuilder
    private func row(_ line: LyricLine?, isCurrent: Bool, at time: Double?) -> some View {
        Group {
            if let line, isCurrent, let time, line.words != nil {
                karaoke(line: line, at: time)
            } else if let line {
                Text(verbatim: line.text).foregroundStyle(.white.opacity(alpha(isCurrent)))
            } else {
                Text(verbatim: " ")
            }
        }
        .font(.system(size: fontSize, weight: isCurrent ? .semibold : .regular))
        .lineLimit(1)
        .truncationMode(.tail)
        .multilineTextAlignment(alignment.text)
    }

    /// Concatenated `Text` runs rather than an HStack: a single Text still
    /// truncates at the tail when the line is wider than the tile.
    private func karaoke(line: LyricLine, at time: Double) -> Text {
        let words = line.words ?? []
        let active = NowPlayingLyrics.activeWordIndex(line: line, at: time)
        var composed = Text(verbatim: "")
        for (index, word) in words.enumerated() {
            composed = composed + Text(verbatim: word.text).foregroundStyle(color(for: index, active: active))
        }
        return composed
    }

    private func color(for index: Int, active: Int?) -> Color {
        guard let active else { return .white.opacity(alpha(false)) }
        if index == active { return accent }
        return .white.opacity(index < active ? alpha(true) : alpha(false))
    }

    private func alpha(_ isCurrent: Bool) -> Double {
        (isCurrent ? 0.95 : 0.45) * brightness
    }
}
