import Testing
import Foundation
@testable import Portal

/// Coverage for `Curriculum` — step completion, progress rollup, ordering, and
/// the agent-JSON parser. Pure model logic; no store or view dependencies.
@Suite("Curriculum")
internal struct CurriculumTests {

    // MARK: - Fixtures

    private func question(_ correct: String = "A") -> QuizQuestion {
        QuizQuestion(
            q: "What is 2 + 2?",
            options: ["A) 4", "B) 5", "C) 6", "D) 7"],
            correct: correct,
            explanation: "Arithmetic."
        )
    }

    private func lesson(_ title: String) -> CurriculumStep {
        CurriculumStep(title: title, kind: .lesson(markdown: "# \(title)\n\nBody."))
    }

    private func quiz(_ title: String, count: Int = 5) -> CurriculumStep {
        CurriculumStep(title: title, kind: .quiz(questions: (0..<count).map { _ in question() }))
    }

    /// Two modules: [lesson, quiz] and [lesson, lesson, quiz] — 5 steps total.
    private func course() -> Curriculum {
        Curriculum(
            title: "Linear Algebra",
            summary: "Vectors through eigenvalues.",
            modules: [
                CurriculumModule(
                    title: "Vectors",
                    overview: "The basics.",
                    steps: [lesson("What is a vector"), quiz("Vectors check")]
                ),
                CurriculumModule(
                    title: "Matrices",
                    overview: "",
                    steps: [lesson("Matrix product"), lesson("Determinants"), quiz("Matrices check")]
                ),
            ]
        )
    }

    // MARK: - Structure

    @Test("steps flatten in module order")
    internal func ordersStepsAcrossModules() {
        let subject = course()
        #expect(subject.totalSteps == 5)
        #expect(subject.orderedSteps.map(\.title) == [
            "What is a vector",
            "Vectors check",
            "Matrix product",
            "Determinants",
            "Matrices check",
        ])
    }

    @Test("step kind drives icon and label")
    internal func describesStepKinds() {
        #expect(lesson("x").kindLabel == "Lesson")
        #expect(!lesson("x").isQuiz)
        #expect(quiz("y", count: 3).kindLabel == "Quiz · 3 questions")
        #expect(quiz("y", count: 1).kindLabel == "Quiz · 1 question")
        #expect(quiz("y").isQuiz)
    }

    @Test("a step's owning module is discoverable")
    internal func findsOwningModule() throws {
        let subject = course()
        let step = try #require(subject.orderedSteps.last)
        #expect(subject.module(containing: step)?.title == "Matrices")
    }

    // MARK: - Completion

    @Test("a fresh course has no progress")
    internal func startsEmpty() {
        let subject = course()
        #expect(subject.completedCount == 0)
        #expect(subject.progressFraction == 0)
        #expect(!subject.isFinished)
        #expect(subject.averageQuizScore == nil)
    }

    @Test("a read lesson counts as complete")
    internal func completesLessonOnRead() throws {
        var subject = course()
        let step = try #require(subject.orderedSteps.first)
        subject.markLessonRead(stepID: step.id)

        #expect(subject.isComplete(step))
        #expect(subject.completedCount == 1)
    }

    @Test("re-reading a lesson keeps the original completion time")
    internal func lessonCompletionIsIdempotent() throws {
        var subject = course()
        let step = try #require(subject.orderedSteps.first)
        subject.markLessonRead(stepID: step.id)
        let first = try #require(subject.progress(for: step)?.completedAt)

        subject.markLessonRead(stepID: step.id)
        #expect(subject.progress(for: step)?.completedAt == first)
        // Attempts still climb — the timestamp is what's pinned.
        #expect(subject.progress(for: step)?.attempts == 2)
    }

    @Test("a quiz completes only at or above the pass threshold")
    internal func quizNeedsPassingScore() throws {
        var subject = course()
        let step = try #require(subject.orderedSteps.first { $0.isQuiz })

        subject.recordQuizAttempt(stepID: step.id, scorePercent: Curriculum.passThreshold - 1)
        #expect(!subject.isComplete(step))
        #expect(subject.needsRetry(step))

        subject.recordQuizAttempt(stepID: step.id, scorePercent: Curriculum.passThreshold)
        #expect(subject.isComplete(step))
        #expect(!subject.needsRetry(step))
    }

    @Test("a quiz keeps its best score, not its latest")
    internal func quizKeepsBestScore() throws {
        var subject = course()
        let step = try #require(subject.orderedSteps.first { $0.isQuiz })

        subject.recordQuizAttempt(stepID: step.id, scorePercent: 100)
        subject.recordQuizAttempt(stepID: step.id, scorePercent: 40)

        #expect(subject.progress(for: step)?.bestScorePercent == 100)
        // A worse retake can't un-complete a passed step.
        #expect(subject.isComplete(step))
        #expect(subject.progress(for: step)?.attempts == 2)
    }

    @Test("an untouched quiz doesn't read as needing retry")
    internal func untouchedQuizIsNotRetry() throws {
        let subject = course()
        let step = try #require(subject.orderedSteps.first { $0.isQuiz })
        #expect(!subject.needsRetry(step))
        #expect(!subject.isComplete(step))
    }

    @Test("a lesson never reads as needing retry")
    internal func lessonNeverNeedsRetry() throws {
        var subject = course()
        let step = try #require(subject.orderedSteps.first)
        subject.markLessonRead(stepID: step.id)
        #expect(!subject.needsRetry(step))
    }

    // MARK: - Rollup

    @Test("progress fraction tracks completed steps")
    internal func rollsUpProgress() {
        var subject = course()
        for step in subject.orderedSteps where !step.isQuiz {
            subject.markLessonRead(stepID: step.id)
        }
        // 3 of 5 steps are lessons.
        #expect(subject.completedCount == 3)
        #expect(abs(subject.progressFraction - 0.6) < 0.0001)
        #expect(!subject.isFinished)
    }

    @Test("finishing every step marks the course finished")
    internal func finishesCourse() {
        var subject = course()
        for step in subject.orderedSteps {
            if step.isQuiz {
                subject.recordQuizAttempt(stepID: step.id, scorePercent: 100)
            } else {
                subject.markLessonRead(stepID: step.id)
            }
        }
        #expect(subject.isFinished)
        #expect(subject.progressFraction == 1)
        #expect(subject.nextStep == nil)
    }

    @Test("an empty course is not finished — zero steps isn't done")
    internal func emptyCourseIsNotFinished() {
        let subject = Curriculum(title: "Empty", summary: "", modules: [])
        #expect(!subject.isFinished)
        #expect(subject.progressFraction == 0)
        #expect(subject.nextStep == nil)
    }

    @Test("per-module counts roll up independently")
    internal func rollsUpPerModule() throws {
        var subject = course()
        let vectors = try #require(subject.modules.first)
        subject.markLessonRead(stepID: vectors.steps[0].id)

        #expect(subject.completedCount(in: vectors) == 1)
        let matrices = try #require(subject.modules.last)
        #expect(subject.completedCount(in: matrices) == 0)
    }

    @Test("average quiz score covers only quizzes that were taken")
    internal func averagesQuizScores() throws {
        var subject = course()
        let quizzes = subject.orderedSteps.filter(\.isQuiz)
        #expect(quizzes.count == 2)

        subject.recordQuizAttempt(stepID: quizzes[0].id, scorePercent: 90)
        // Only one quiz taken — the untaken one must not count as a zero.
        #expect(subject.averageQuizScore == 90)

        subject.recordQuizAttempt(stepID: quizzes[1].id, scorePercent: 70)
        #expect(subject.averageQuizScore == 80)
    }

    // MARK: - Next step

    @Test("next step is the first incomplete one in course order")
    internal func findsNextStep() throws {
        var subject = course()
        #expect(subject.nextStep?.title == "What is a vector")

        subject.markLessonRead(stepID: try #require(subject.orderedSteps.first).id)
        #expect(subject.nextStep?.title == "Vectors check")
    }

    @Test("a failed quiz stays the next step")
    internal func failedQuizBlocksAdvance() throws {
        var subject = course()
        let first = try #require(subject.orderedSteps.first)
        subject.markLessonRead(stepID: first.id)

        let quizStep = try #require(subject.orderedSteps.first { $0.isQuiz })
        subject.recordQuizAttempt(stepID: quizStep.id, scorePercent: 20)

        // Not passed, so it's still what "Continue" opens — progress doesn't
        // silently skip past material the learner hasn't cleared.
        #expect(subject.nextStep?.id == quizStep.id)
    }

    @Test("completing out of order still reports the earliest gap")
    internal func nextStepIsEarliestGap() throws {
        var subject = course()
        let steps = subject.orderedSteps
        // Do the last lesson first.
        subject.markLessonRead(stepID: steps[3].id)
        #expect(subject.nextStep?.id == steps[0].id)
    }

    // MARK: - Reset

    @Test("restarting clears progress but keeps content")
    internal func resetsProgress() throws {
        var subject = course()
        for step in subject.orderedSteps {
            if step.isQuiz {
                subject.recordQuizAttempt(stepID: step.id, scorePercent: 100)
            } else {
                subject.markLessonRead(stepID: step.id)
            }
        }
        #expect(subject.isFinished)

        subject.resetProgress()
        #expect(subject.completedCount == 0)
        #expect(subject.totalSteps == 5)
        #expect(subject.averageQuizScore == nil)
    }

    // MARK: - Codable

    @Test("a course round-trips through JSON with progress intact")
    internal func roundTripsThroughJSON() throws {
        var subject = course()
        let step = try #require(subject.orderedSteps.first)
        subject.markLessonRead(stepID: step.id)
        let quizStep = try #require(subject.orderedSteps.first { $0.isQuiz })
        subject.recordQuizAttempt(stepID: quizStep.id, scorePercent: 90)

        let data = try JSONEncoder().encode(subject)
        let decoded = try JSONDecoder().decode(Curriculum.self, from: data)

        #expect(decoded.id == subject.id)
        #expect(decoded.title == subject.title)
        #expect(decoded.totalSteps == subject.totalSteps)
        #expect(decoded.completedCount == subject.completedCount)
        #expect(decoded.progress(for: quizStep)?.bestScorePercent == 90)
    }

    @Test("step kind encodes as a tagged object, readable on disk")
    internal func stepKindEncodesWithDiscriminator() throws {
        let data = try JSONEncoder().encode(CurriculumStepKind.lesson(markdown: "hello"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "lesson")
        #expect(json["markdown"] as? String == "hello")

        let decoded = try JSONDecoder().decode(CurriculumStepKind.self, from: data)
        #expect(decoded == .lesson(markdown: "hello"))
    }
}

// MARK: - Parsing

@Suite("Curriculum Parsing")
internal struct CurriculumParsingTests {

    private let wellFormed = """
        {"curriculum":{"title":"Rust Basics","summary":"Ownership first.","modules":[
          {"title":"Ownership","overview":"Move semantics.","steps":[
            {"type":"lesson","title":"Moves","content":"# Moves\\n\\nValues move."},
            {"type":"quiz","title":"Ownership check","questions":[
              {"q":"What happens on move?","options":["A) copy","B) transfer","C) borrow","D) drop"],
               "correct":"B","explanation":"Ownership transfers."}]}]}]}}
        """

    @Test("a well-formed course parses with modules and steps")
    internal func parsesWellFormed() throws {
        let course = try #require(CurriculumResponse.extract(from: wellFormed))
        #expect(course.title == "Rust Basics")
        #expect(course.summary == "Ownership first.")
        #expect(course.modules.count == 1)
        #expect(course.totalSteps == 2)

        let steps = course.orderedSteps
        #expect(steps[0].kind == .lesson(markdown: "# Moves\n\nValues move."))
        #expect(steps[1].isQuiz)
        guard case .quiz(let questions) = steps[1].kind else {
            Issue.record("expected a quiz step")
            return
        }
        #expect(questions.count == 1)
        #expect(questions[0].correct == "B")
    }

    @Test("markdown code fences are stripped")
    internal func parsesFencedJSON() throws {
        let fenced = "Here's your course:\n\n```json\n\(wellFormed)\n```\n\nEnjoy!"
        let course = try #require(CurriculumResponse.extract(from: fenced))
        #expect(course.title == "Rust Basics")
    }

    @Test("prose around bare JSON is tolerated")
    internal func parsesJSONAmidProse() throws {
        let noisy = "Sure! \(wellFormed) Let me know if you want more depth."
        let course = try #require(CurriculumResponse.extract(from: noisy))
        #expect(course.totalSteps == 2)
    }

    @Test("a missing summary falls back to empty, not failure")
    internal func toleratesMissingSummary() throws {
        let json = """
            {"curriculum":{"title":"T","modules":[{"title":"M","steps":[
              {"type":"lesson","title":"L","content":"body"}]}]}}
            """
        let course = try #require(CurriculumResponse.extract(from: json))
        #expect(course.summary.isEmpty)
        #expect(course.modules.first?.overview.isEmpty == true)
    }

    @Test("a lesson body under markdown or body is still found")
    internal func acceptsAlternateLessonKeys() throws {
        for key in ["markdown", "body"] {
            let json = """
                {"curriculum":{"title":"T","modules":[{"title":"M","steps":[
                  {"type":"lesson","title":"L","\(key)":"alt body"}]}]}}
                """
            let course = try #require(CurriculumResponse.extract(from: json), "key \(key) should parse")
            #expect(course.orderedSteps.first?.kind == .lesson(markdown: "alt body"))
        }
    }

    @Test("a bare course object without the curriculum wrapper parses")
    internal func acceptsUnwrappedCourse() throws {
        let json = """
            {"title":"T","modules":[{"title":"M","steps":[
              {"type":"lesson","title":"L","content":"body"}]}]}
            """
        let course = try #require(CurriculumResponse.extract(from: json))
        #expect(course.title == "T")
    }

    @Test("a step type in mixed case still parses")
    internal func normalizesStepType() throws {
        let json = """
            {"curriculum":{"title":"T","modules":[{"title":"M","steps":[
              {"type":"Lesson","title":"L","content":"body"}]}]}}
            """
        let course = try #require(CurriculumResponse.extract(from: json))
        #expect(course.orderedSteps.count == 1)
    }

    @Test("an empty lesson body is dropped rather than shown blank")
    internal func dropsEmptyLesson() {
        let json = """
            {"curriculum":{"title":"T","modules":[{"title":"M","steps":[
              {"type":"lesson","title":"L","content":"   "}]}]}}
            """
        // The only step is unusable, so the module empties and the course fails
        // rather than persisting an outline that leads nowhere.
        #expect(CurriculumResponse.extract(from: json) == nil)
    }

    @Test("a quiz step with no questions is dropped")
    internal func dropsQuestionlessQuiz() throws {
        let json = """
            {"curriculum":{"title":"T","modules":[{"title":"M","steps":[
              {"type":"lesson","title":"L","content":"body"},
              {"type":"quiz","title":"Q","questions":[]}]}]}}
            """
        let course = try #require(CurriculumResponse.extract(from: json))
        #expect(course.totalSteps == 1)
        #expect(course.orderedSteps.first?.isQuiz == false)
    }

    @Test("a module whose steps all fail is dropped")
    internal func dropsEmptyModule() throws {
        let json = """
            {"curriculum":{"title":"T","modules":[
              {"title":"Broken","steps":[{"type":"quiz","title":"Q","questions":[]}]},
              {"title":"Good","steps":[{"type":"lesson","title":"L","content":"body"}]}]}}
            """
        let course = try #require(CurriculumResponse.extract(from: json))
        #expect(course.modules.map(\.title) == ["Good"])
    }

    @Test("a course with no usable module yields nil")
    internal func rejectsFullyEmptyCourse() {
        let json = #"{"curriculum":{"title":"T","summary":"s","modules":[]}}"#
        #expect(CurriculumResponse.extract(from: json) == nil)
    }

    @Test("non-course JSON and prose are rejected")
    internal func rejectsUnrelatedInput() {
        #expect(CurriculumResponse.extract(from: "Here's a thought about vectors.") == nil)
        #expect(CurriculumResponse.extract(from: "{}") == nil)
        #expect(CurriculumResponse.extract(from: #"{"questions":[]}"#) == nil)
    }

    @Test("a plain quiz response is not mistaken for a course")
    internal func doesNotClaimPlainQuiz() {
        // This is the shape `QuizResponse` owns; the curriculum parser runs
        // first in ChatViewModel, so it must decline it.
        let quizJSON = """
            {"questions":[{"q":"Q?","options":["A) a","B) b","C) c","D) d"],
             "correct":"A","explanation":"because"}]}
            """
        #expect(CurriculumResponse.extract(from: quizJSON) == nil)
    }

    @Test("question fields survive parsing intact")
    internal func preservesQuestionFields() throws {
        let course = try #require(CurriculumResponse.extract(from: wellFormed))
        guard case .quiz(let questions) = course.orderedSteps[1].kind,
              let first = questions.first else {
            Issue.record("expected a quiz step with questions")
            return
        }
        #expect(first.q == "What happens on move?")
        #expect(first.options.count == 4)
        #expect(first.explanation == "Ownership transfers.")
        #expect(first.correctAnswer == "B) transfer")
    }

    @Test("a lenient question accepts `question` in place of `q`")
    internal func acceptsAlternateQuestionKey() throws {
        let json = """
            {"curriculum":{"title":"T","modules":[{"title":"M","steps":[
              {"type":"quiz","title":"Q","questions":[
                {"question":"Alt key?","options":["A) y","B) n"],"correct":"A"}]}]}]}}
            """
        let course = try #require(CurriculumResponse.extract(from: json))
        guard case .quiz(let questions) = course.orderedSteps[0].kind else {
            Issue.record("expected a quiz step")
            return
        }
        #expect(questions.first?.q == "Alt key?")
        // No explanation supplied — empty, not a parse failure.
        #expect(questions.first?.explanation.isEmpty == true)
    }

    @Test("a quiz step with no type field is detected by its questions alone")
    internal func detectsQuizByQuestionsAlone() throws {
        // The strict decoder requires `type` (non-optional in RawStep), so a
        // step that omits it fails strict decode. The lenient parser then
        // infers quiz-ness from the presence of `questions` — the fallback for
        // an agent that writes a quiz without labeling it.
        let json = """
            {"curriculum":{"title":"T","modules":[{"title":"M","steps":[
              {"title":"Q","questions":[
                {"q":"Capital of France?","options":["A) Paris","B) Lyon"],
                 "correct":"A","explanation":"Geography."}]}]}]}}
            """
        let course = try #require(CurriculumResponse.extract(from: json))
        #expect(course.totalSteps == 1)
        #expect(course.orderedSteps.first?.isQuiz == true)
    }

    @Test("a parsed course starts with no progress")
    internal func parsedCourseHasNoProgress() throws {
        let course = try #require(CurriculumResponse.extract(from: wellFormed))
        #expect(course.completedCount == 0)
        #expect(course.nextStep?.title == "Moves")
    }
}
