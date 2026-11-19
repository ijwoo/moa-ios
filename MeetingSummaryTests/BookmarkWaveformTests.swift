import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import MeetingSummary

struct BookmarkTests {
    @Test func rangeStartsTenSecondsEarlier() {
        #expect(Bookmark.range(for: 30, duration: 100) == 20...35)
    }

    @Test func rangeIsClampedToRecording() {
        #expect(Bookmark.range(for: 4, duration: 100) == 0...9)
        #expect(Bookmark.range(for: 98, duration: 100) == 88...100)
    }

    @Test func overlappingRangesAreMerged() {
        let ranges = Bookmark.mergedRanges(times: [50, 12, 18], duration: 100)
        // 12 → 2...17, 18 → 8...23 (겹침 → 2...23), 50 → 40...55
        #expect(ranges == [2...23, 40...55])
    }

    @MainActor
    @Test func deletingMeetingDeletesBookmarks() throws {
        let container = try ModelContainer(
            for: Meeting.self, Summary.self, ActionItem.self, Utterance.self, Bookmark.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let meeting = Meeting(title: "면담")
        context.insert(meeting)
        meeting.bookmarks.append(Bookmark(time: 3))
        try context.save()
        #expect(meeting.sortedBookmarks.map(\.time) == [3])
        context.delete(meeting)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Bookmark>()) == 0)
    }
}

struct WaveformTests {
    @Test func builderEmitsPeakPerBin() {
        var builder = WaveformBuilder(sampleRate: 100) // 0.1초 = 10샘플
        for i in 0..<25 { builder.add(sample: i == 3 ? -0.8 : 0.1) }
        #expect(builder.peaks == [0.8, 0.1]) // 마지막 5샘플은 아직 한 칸이 안 됨
    }

    @Test func builderReadsInt16Buffers() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 100, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 10))
        buffer.frameLength = 10
        for i in 0..<10 { buffer.int16ChannelData![0][i] = i == 5 ? Int16.max / 2 : 0 }
        var builder = WaveformBuilder(sampleRate: 100)
        builder.add(buffer)
        #expect(builder.peaks.count == 1)
        #expect(abs(builder.peaks[0] - 0.5) < 0.01)
    }

    @Test func encodeDecodeRoundTrip() {
        let peaks: [Float] = [0, 0.25, 1, 0.5]
        #expect(Waveform.decode(Waveform.encode(peaks)) == peaks)
    }

    @Test func downsampleKeepsMaximum() {
        #expect(Waveform.downsample([0.1, 0.9, 0.2, 0.3, 0.5, 0.4], to: 3) == [0.9, 0.3, 0.5])
        #expect(Waveform.downsample([0.1, 0.2], to: 10) == [0.1, 0.2])
    }

    @Test func normalizedScalesToLoudest() {
        let result = Waveform.normalized([0.25, 0.5, 0])
        #expect(result[1] == 1)
        #expect(abs(result[0] - 0.7071) < 0.001)
        #expect(result[2] == 0)
    }
}
