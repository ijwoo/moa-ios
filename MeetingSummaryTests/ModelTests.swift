import Foundation
import SwiftData
import Testing
@testable import MeetingSummary

@MainActor
struct ModelTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Meeting.self, Summary.self, ActionItem.self, Utterance.self, Bookmark.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @Test func newMeetingStartsRecording() {
        let meeting = Meeting(title: "면담")
        #expect(meeting.status == .recording)
        #expect(meeting.transcript.isEmpty)
        #expect(meeting.summary == nil)
    }

    @Test func validTransitions() throws {
        let meeting = Meeting(title: "면담")
        try meeting.transition(to: .processing)
        try meeting.transition(to: .failed, failureMessage: "네트워크 오류")
        #expect(meeting.failureMessage == "네트워크 오류")
        try meeting.transition(to: .processing)
        #expect(meeting.failureMessage == nil)
        try meeting.transition(to: .ready)
        #expect(meeting.status == .ready)
    }

    @Test func invalidTransitionThrowsAndKeepsState() {
        let meeting = Meeting(title: "면담")
        #expect(throws: MeetingStatusError.invalidTransition(from: .recording, to: .ready)) {
            try meeting.transition(to: .ready)
        }
        #expect(meeting.status == .recording)
    }

    @Test func persistsSummaryWithOptionalOwnerAndDue() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "면담", status: .ready)
        meeting.summary = Summary(
            topic: "주제",
            body: "요약",
            actionItems: [
                ActionItem(task: "B", owner: nil, dueText: nil, order: 1),
                ActionItem(task: "A", owner: "김지원", dueText: "금요일", order: 0),
            ]
        )
        context.insert(meeting)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<Meeting>()).first)
        let items = try #require(fetched.summary?.sortedActionItems)
        #expect(items.map(\.task) == ["A", "B"])
        #expect(items[1].owner == nil)
        #expect(items[1].dueText == nil)
        #expect(items.allSatisfy { !$0.isAddedToReminders })
    }

    @Test func deletingMeetingCascades() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "면담")
        meeting.summary = Summary(topic: "t", body: "b", actionItems: [ActionItem(task: "x")])
        context.insert(meeting)
        try context.save()

        context.delete(meeting)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Summary>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ActionItem>()) == 0)
    }

    @Test func utterancesAreSortedAndAppendToTranscript() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "면담")
        context.insert(meeting)
        meeting.appendUtterance(Utterance(start: 0, end: 3, text: "첫 문장."))
        meeting.appendUtterance(Utterance(start: 3, end: 6, text: "둘째 문장."))
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<Meeting>()).first)
        #expect(fetched.sortedUtterances.map(\.text) == ["첫 문장.", "둘째 문장."])
        #expect(fetched.transcript == "첫 문장. 둘째 문장.")
        #expect(fetched.sortedUtterances.allSatisfy { $0.speaker == nil })
        #expect(fetched.isRecordingComplete == false)
    }

    @Test func deletingMeetingDeletesUtterances() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "면담")
        context.insert(meeting)
        meeting.appendUtterance(Utterance(start: 0, end: 1, text: "가"))
        try context.save()
        context.delete(meeting)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Utterance>()) == 0)
    }
}
