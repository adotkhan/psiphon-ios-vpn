/*
 * Copyright (c) 2020, Psiphon Inc.
 * All rights reserved.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

import Foundation

typealias LogTag = String

enum LogLevel: Int {
    case info
    case warn
    case error
}

protocol FeedbackLogHandler {
    
    func fatalError(type: String, message: String)
    
    func feedbackLog(level: LogLevel, type: String, message: String)
    
}

struct StdoutFeedbackLogger: FeedbackLogHandler {
    
    func fatalError(type: String, message: String) {
        print("[FatalError] type: '\(type)' message: '\(message)'")
    }
    
    func feedbackLog(level: LogLevel, type: String, message: String) {
        print("[\(String(describing: level))] type: '\(type)' message: '\(message)'")
    }
    
}

struct LogMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation,
Equatable, CustomStringConvertible, CustomStringFeedbackDescription, FeedbackDescription {
    typealias StringLiteralType = String
    
    private var value: String
    
    public init(stringLiteral value: String) {
        self.value = value
    }
    
    public var description: String {
        return self.value
    }
}

public struct FeedbackLogger {
    
    let handler: FeedbackLogHandler
    
    init(_ handler: FeedbackLogHandler) {
        self.handler = handler
    }
    
    func fatalError(
        _ message: LogMessage, file: String = #file, line: UInt = #line
    ) -> Never {
        let tag = "\(file.lastPathComponent):\(line)"
        handler.fatalError(type: tag, message: makeFeedbackEntry(message))
        Swift.fatalError(tag)
    }

    func precondition(
        _ condition: @autoclosure () -> Bool, _ message: LogMessage,
        file: String = #file, line: UInt = #line
    ) {
        guard condition() else {
            fatalError(message, file: file, line: line)
        }
    }

    func preconditionFailure(
        _ message: LogMessage, file: String = #file, line: UInt = #line
    ) -> Never {
        fatalError(message, file: file, line: line)
    }

    func log(
        _ level: LogLevel, file: String = #file, line: Int = #line, _ message: LogMessage
    ) -> Effect<Never> {
        log(level, type: "\(file.lastPathComponent):\(line)", value: message.description)
    }

    func log<T: FeedbackDescription>(
        _ level: LogLevel, file: String = #file, line: Int = #line, _ value: T
    ) -> Effect<Never> {
        log(level, type: "\(file.lastPathComponent):\(line)", value: String(describing: value))
    }

    func log<T: CustomFieldFeedbackDescription>(
        _ level: LogLevel, file: String = #file, line: Int = #line, _ value: T
    ) -> Effect<Never> {
        log(level, type: "\(file.lastPathComponent):\(line)", value: value.description)
    }

    func log(_ level: LogLevel, tag: LogTag, _ message: LogMessage) -> Effect<Never> {
        log(level, type: tag, value: message.description)
    }

    func log<T: FeedbackDescription>(
        _ level: LogLevel, tag: LogTag, _ value: T
    ) -> Effect<Never> {
        log(level, type: tag, value: String(describing: value))
    }

    func log<T: CustomFieldFeedbackDescription>(
        _ level: LogLevel, tag: LogTag,  _ value: T
    ) -> Effect<Never> {
        log(level, type: tag, value: value.description)
    }

    private func log(_ level: LogLevel, type: String, value: String) -> Effect<Never> {
        .fireAndForget {
            self.handler.feedbackLog(level: level, type: type, message: value)
        }
    }

    func immediate(
        _ level: LogLevel, _ value: LogMessage, file: String = #file, line: UInt = #line
    ) {
        let tag = "\(file.lastPathComponent):\(line)"
        let message = makeFeedbackEntry(value)
        handler.feedbackLog(level: level, type: tag, message: message)
    }
    
}

/// Creates a string representation of `value` fit for sending in feedback.
/// - Note: Escapes double-quotes `"`, and removes "Psiphon" and "Swift" module names.
func makeFeedbackEntry<T: FeedbackDescription>(_ value: T) -> String {
    normalizeFeedbackDescriptionTypes(String(describing: value))
}

/// Creates a string representation of `value` fit for sending in feedback.
/// - Note: Escapes double-quotes `"`, and removes "Psiphon" and "Swift" module names.
func makeFeedbackEntry<T: CustomFieldFeedbackDescription>(_ value: T) -> String {
    normalizeFeedbackDescriptionTypes(value.description)
}

fileprivate func normalizeFeedbackDescriptionTypes(_ value: String) -> String {
    value.replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "Psiphon.", with: "")
        .replacingOccurrences(of: "Swift.", with: "")
}

extension String {
    
    fileprivate var lastPathComponent: String {
        if let path = URL(string: self) {
            return path.lastPathComponent
        } else {
            return self
        }
    }
    
}

// MARK: Default FeedbackDescription conformances

extension Optional: FeedbackDescription {}