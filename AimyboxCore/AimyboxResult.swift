//
//  AimyboxResult.swift
//  AimyboxCore
//
//  Created by Vladyslav Popovych on 30.11.2019.
//  Copyright © 2019 Just Ai. All rights reserved.
//

import Foundation

public extension Aimybox {
    /**
     Used to support versions of swift < 5.0.
     */
    enum Result<T, E> where E: Error {
        case success(T)
        case failure(E)
    }
}

public typealias SpeechToTextResult = Aimybox.Result<SpeechToTextEvent, SpeechToTextError>

public typealias TextToSpeechResult = Aimybox.Result<TextToSpeechEvent, TextToSpeechError>
