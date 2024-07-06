//
//  ChatViewModel.swift
//  Amazon Bedrock Client for Mac
//
//  Created by Na, Sanghwa on 6/28/24.
//

import SwiftUI
import Combine

class ChatViewModel: ObservableObject {
    let chatId: String
    let chatManager: ChatManager
    let sharedImageDataSource: SharedImageDataSource
    
    @ObservedObject var backendModel: BackendModel
    @Published var chatModel: ChatModel
    @Published var messages: [MessageData] = []
    @Published var userInput: String = ""
    @Published var isMessageBarDisabled: Bool = false
    @Published var isSending: Bool = false
    @Published var isStreamingEnabled: Bool
    @Published var selectedPlaceholder: String
    @Published var scrollToBottomTrigger: UUID?
    @Published var emptyText: String = ""
    
    private var cancellables: Set<AnyCancellable> = []
    private var messageTask: Task<Void, Never>?
    
    init(chatId: String, backendModel: BackendModel, chatManager: ChatManager = .shared, sharedImageDataSource: SharedImageDataSource) {
        self.chatId = chatId
        self.backendModel = backendModel
        self.chatManager = chatManager
        self.sharedImageDataSource = sharedImageDataSource
        
        guard let model = chatManager.getChatModel(for: chatId) else {
            fatalError("Chat model not found for id: \(chatId)")
        }
        self.chatModel = model
        
        let key = "isStreamingEnabled_\(chatId)"
        let savedValue = UserDefaults.standard.bool(forKey: key)
        let defaultValue = model.id.contains("mistral") || model.id.contains("claude") || model.id.contains("llama")
        self.isStreamingEnabled = savedValue ? savedValue : defaultValue
        
        self.selectedPlaceholder = ChatViewModel.placeholderMessages.randomElement() ?? "No messages"
        
        // 모든 프로퍼티 초기화 후에 setupBindings 호출
        setupBindings()
    }
    
    @MainActor
    private func loadChatModel() async {
        // 채팅 모델이 준비될 때까지 대기
        for _ in 0..<10 { // 최대 10번 시도
            if let model = chatManager.getChatModel(for: chatId) {
                self.chatModel = model
                setupStreamingEnabled()
                setupBindings()
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1초 대기
        }
        // 채팅 모델을 찾지 못한 경우
        print("Error: Chat model not found for id: \(chatId)")
    }
    
    private func setupStreamingEnabled() {
        let key = "isStreamingEnabled_\(chatId)"
        let savedValue = UserDefaults.standard.bool(forKey: key)
        let defaultValue = chatModel.id.contains("mistral") || chatModel.id.contains("claude") || chatModel.id.contains("llama")
        self.isStreamingEnabled = savedValue ? savedValue : defaultValue
    }
    
    private func setupBindings() {
        chatManager.$chats
            .map { [weak self] chats in
                chats.first { $0.chatId == self?.chatId }
            }
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .assign(to: \.chatModel, on: self)
            .store(in: &cancellables)
        
        $isStreamingEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newValue in
                guard let self = self else { return }
                UserDefaults.standard.set(newValue, forKey: "isStreamingEnabled_\(self.chatId)")
            }
            .store(in: &cancellables)
    }
    
    func loadInitialData() {
        messages = chatManager.getMessages(for: chatId)
        scrollToBottom()
    }
    
    func scrollToBottom() {
        scrollToBottomTrigger = UUID()
    }
    
    func sendMessage() {
        guard !userInput.isEmpty else { return }
        
        messageTask?.cancel()
        messageTask = Task { await sendMessageAsync() }
    }
    
    private func sendMessageAsync() async {
        await MainActor.run {
            chatManager.setIsLoading(true, for: chatId)
            isMessageBarDisabled = true
        }
        
        let tempInput = userInput
        Task {
            await updateChatTitle(with: tempInput)
        }
        
        let userMessage = createUserMessage()
        await addMessage(userMessage)
        
        await MainActor.run {
            userInput = ""
            sharedImageDataSource.images.removeAll()
            sharedImageDataSource.fileExtensions.removeAll()
        }
        
        do {
            if chatModel.id.contains("claude-3") {
                try await handleClaudeMessage(userMessage)
            } else {
                try await handleStandardMessage(userMessage)
            }
        } catch {
            await handleModelError(error)
        }
        
        await MainActor.run {
            isMessageBarDisabled = false
            chatManager.setIsLoading(false, for: chatId)
        }
    }
    
    func cancelSending() {
        messageTask?.cancel()
        chatManager.setIsLoading(false, for: chatId)
    }
    
    private func createUserMessage() -> MessageData {
        let imageBase64Strings = sharedImageDataSource.images.enumerated().compactMap { index, image in
            let fileExtension = sharedImageDataSource.fileExtensions.indices.contains(index)
            ? sharedImageDataSource.fileExtensions[index]
            : ""
            let (base64String, _) = base64EncodeImage(image, withExtension: fileExtension)
            
            if let base64String = base64String {
                print("Image at index \(index) encoded successfully: \(base64String.prefix(30))...") // base64String의 앞 30글자만 출력
            } else {
                print("Failed to encode image at index \(index)")
            }
            
            return base64String
        }
        
        let userMessage = MessageData(id: UUID(), text: userInput, user: "User", isError: false, sentTime: Date(), imageBase64Strings: imageBase64Strings)
        return userMessage
    }
    
    private func handleClaudeMessage(_ userMessage: MessageData) async throws {
        let contentBlocks = createContentBlocks(from: userMessage)
        let message = ClaudeMessageRequest.Message(role: "user", content: contentBlocks)
        chatManager.addClaudeHistory(message, for: chatId)
        
        if isStreamingEnabled {
            try await invokeClaudeModelStream(claudeMessages: chatManager.getClaudeHistory(for: chatId))
        } else {
            try await invokeClaudeModel(claudeMessages: chatManager.getClaudeHistory(for: chatId))
        }
    }
    
    private func handleStandardMessage(_ userMessage: MessageData) async throws {
        var history = chatManager.getHistory(for: chatId)
        let trimmedHistory = trimHistory(history)
        
        history += formatHistoryAddition(userInput: userMessage.text)
        
        let prompt = createPrompt(history: trimmedHistory, userInput: userMessage.text)
        
        chatManager.setHistory(history, for: chatId)
        
        if isStreamingEnabled {
            try await invokeModelStream(prompt: prompt)
        } else {
            try await invokeModel(prompt: prompt)
        }
    }
    
    private func trimHistory(_ history: String) -> String {
        if history.count > 50000 {
            return String(history.suffix(50000))
        }
        return history
    }
    
    private func formatHistoryAddition(userInput: String) -> String {
        if chatModel.id.contains("llama3") {
            return "user\n\n\(userInput)"
        } else {
            return "\nHuman: \(userInput)"
        }
    }
    
    @MainActor
    private func addMessage(_ message: MessageData) {
        messages.append(message)
        chatManager.addMessage(message, for: chatId)
        scrollToBottom()
    }
    
    private func handleModelError(_ error: Error) async {
        print("Error invoking the model: \(error)")
        let errorMessage = MessageData(id: UUID(), text: "Error invoking the model: \(error)", user: "System", isError: true, sentTime: Date())
        await addMessage(errorMessage)
    }
    
    private func createPrompt(history: String, userInput: String) -> String {
        // Implement prompt creation logic based on chat model
        return "The following is a friendly conversation between a human and an AI.\nCurrent conversation:\n\(history)\n\nHuman: \(userInput)\nAI:"
    }
    
    func invokeClaudeModelStream(claudeMessages: [ClaudeMessageRequest.Message]) async throws {
        var isFirstChunk = true
        let modelId = chatModel.id
        let response = try await backendModel.backend.invokeClaudeModelStream(withId: modelId, messages: claudeMessages)
        
        var streamedText = ""
        
        for try await event in response {
            switch event {
            case .chunk(let part):
                guard let jsonObject = try JSONSerialization.jsonObject(with: part.bytes!, options: []) as? [String: Any] else {
                    print("Failed to decode JSON")
                    continue
                }
                
                if let delta = jsonObject["delta"] as? [String: Any],
                   let type = delta["type"] as? String {
                    switch type {
                    case "text_delta":
                        if let text = delta["text"] as? String {
                            streamedText += text
                            handleContentBlockDelta(jsonObject, isFirstChunk: &isFirstChunk)
                        }
                    case "message_delta":
                        handleMessageDelta(jsonObject)
                    default:
                        print("Unhandled event type: \(type)")
                    }
                }
                
            case .sdkUnknown(let unknown):
                print("Unknown SDK event: \"\(unknown)\"")
            }
        }
        
        let assistantMessage = MessageData(id: UUID(), text: streamedText.trimmingCharacters(in: .whitespacesAndNewlines), user: chatModel.name, isError: false, sentTime: Date())
        chatManager.addMessage(assistantMessage, for: chatId)
        
        let assistantClaudeMessage = ClaudeMessageRequest.Message(role: "assistant", content: [.init(type: "text", text: assistantMessage.text)])
        chatManager.addClaudeHistory(assistantClaudeMessage, for: chatId)
    }
    
    /// Handles message delta events.
    private func handleMessageDelta(_ jsonObject: [String: Any]) {
        if let delta = jsonObject["delta"] as? [String: Any],
           let stopReason = delta["stop_reason"] as? String,
           let stopSequence = delta["stop_sequence"] as? String,
           let usage = delta["usage"] as? [String: Any],
           let outputTokens = usage["output_tokens"] as? Int {
            DispatchQueue.main.async {
                print("\nStop reason: \(stopReason)")
                print("Stop sequence: \(stopSequence)")
                print("Output tokens: \(outputTokens)")
            }
        }
    }
    
    /// Handles content block delta events.
    private func handleContentBlockDelta(_ jsonObject: [String: Any], isFirstChunk: inout Bool) {
        if let delta = jsonObject["delta"] as? [String: Any],
           let type = delta["type"] as? String, type == "text_delta",
           let text = delta["text"] as? String {
            let shouldCreateNewMessage = isFirstChunk
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if shouldCreateNewMessage {
                    self.messages.append(MessageData(id: UUID(), text: text, user: self.chatModel.name, isError: false, sentTime: Date()))
                } else {
                    if var lastMessage = self.messages.last {
                        lastMessage.text += text
                        self.messages[self.messages.count - 1] = lastMessage
                    }
                }
                self.objectWillChange.send()
            }
            isFirstChunk = false
        }
    }
    
    /// Invokes the Claude model.
    func invokeClaudeModel(claudeMessages: [ClaudeMessageRequest.Message]) async throws {
        let modelId = chatModel.id
        let data = try await backendModel.backend.invokeClaudeModel(withId: modelId, messages: claudeMessages)
        let response = try JSONDecoder().decode(ClaudeMessageResponse.self, from: data)
        
        if let firstText = response.content.first?.text {
            let assistantMessage = MessageData(id: UUID(), text: firstText.trimmingCharacters(in: .whitespacesAndNewlines), user: chatModel.name, isError: false, sentTime: Date())
            messages.append(assistantMessage)
            chatManager.addMessage(assistantMessage, for: chatId)
            
            // Add assistant message to Claude history
            let assistantClaudeMessage = ClaudeMessageRequest.Message(role: "assistant", content: [.init(type: "text", text: assistantMessage.text)])
            chatManager.addClaudeHistory(assistantClaudeMessage, for: chatId)
        }
    }
    
    private func invokeModelStream(prompt: String) async throws {
        var isFirstChunk = true
        let modelId = chatModel.id
        let response = try await backendModel.backend.invokeModelStream(withId: modelId, prompt: prompt)
        let modelType = backendModel.backend.getModelType(modelId)
        
        var streamedText = ""
        
        for try await event in response {
            switch event {
            case .chunk(let part):
                let jsonObject = try JSONSerialization.jsonObject(with: part.bytes!, options: [])
                handleModelChunk(jsonObject, modelType: modelType, isFirstChunk: &isFirstChunk)
                if let chunkText = extractTextFromChunk(jsonObject, modelType: modelType) {
                    streamedText += chunkText
                }
            case .sdkUnknown(let unknown):
                print("Unknown: \"\(unknown)\"")
            }
        }
        
        // After streaming is complete, update the history
        let assistantMessage = MessageData(id: UUID(), text: streamedText.trimmingCharacters(in: .whitespacesAndNewlines), user: chatModel.name, isError: false, sentTime: Date())
        chatManager.addMessage(assistantMessage, for: chatId)
        
        var history = chatManager.getHistory(for: chatId)
        if modelType == .llama3 {
            history += "assistant\n\n\(assistantMessage.text)\n\n"
        } else {
            history += "\nAssistant: \(assistantMessage.text)\n"
        }
        chatManager.setHistory(history, for: chatId)
    }
    
    private func extractTextFromChunk(_ jsonObject: Any, modelType: ModelType) -> String? {
        if let dict = jsonObject as? [String: Any] {
            switch modelType {
            case .titan:
                return dict["outputText"] as? String
            case .claude:
                return dict["completion"] as? String
            case .llama2, .llama3, .mistral:
                if let generation = dict["generation"] as? String {
                    return generation
                } else if let outputs = dict["outputs"] as? [[String: Any]],
                          let text = outputs.first?["text"] as? String {
                    return text
                }
            default:
                return nil
            }
        }
        return nil
    }
    
    /// Handles model chunk events.
    private func handleModelChunk(_ jsonObject: Any, modelType: ModelType, isFirstChunk: inout Bool) {
        if let chunkText = extractTextFromChunk(jsonObject, modelType: modelType) {
            let shouldCreateNewMessage = isFirstChunk
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if shouldCreateNewMessage {
                    let newMessage = MessageData(id: UUID(), text: chunkText, user: self.chatModel.name, isError: false, sentTime: Date())
                    self.messages.append(newMessage)
                } else {
                    if var lastMessage = self.messages.last {
                        lastMessage.text += chunkText
                        self.messages[self.messages.count - 1] = lastMessage
                    }
                }
                self.objectWillChange.send()
            }
            isFirstChunk = false
        }
    }
    
    /// Handles processed text.
    private func handleProcessedText(_ processedText: String, modelType: ModelType, isFirstChunk: inout Bool) {
        if isFirstChunk {
            isFirstChunk = false
            emptyText.append(processedText.trimmingCharacters(in: .whitespacesAndNewlines))
            messages.append(MessageData(id: UUID(), text: emptyText, user: chatModel.name, isError: false, sentTime: Date()))
        } else {
            emptyText.append(processedText)
            messages[messages.count - 1].text = emptyText
        }
    }
    
    private func invokeModel(prompt: String) async throws {
        let modelId = chatModel.id
        let modelType = backendModel.backend.getModelType(modelId)
        
        if modelType != .stableDiffusion {
            let data = try await backendModel.backend.invokeModel(withId: modelId, prompt: prompt)
            try handleModelResponse(data, modelType: modelType)
        } else {
            let data = try await backendModel.backend.invokeStableDiffusionModel(withId: modelId, prompt: prompt)
            try handleStableDiffusionResponse(data)
        }
    }
    
    /// Handles model response.
    private func handleModelResponse(_ data: Data, modelType: ModelType) throws {
        let assistantMessage: MessageData
        
        switch modelType {
        case .claude:
            let response = try backendModel.backend.decode(data) as InvokeClaudeResponse
            assistantMessage = MessageData(id: UUID(), text: response.completion.trimmingCharacters(in: .whitespacesAndNewlines), user: chatModel.name, isError: false, sentTime: Date())
            
        case .titan:
            let response = try backendModel.backend.decode(data) as InvokeTitanResponse
            assistantMessage = MessageData(id: UUID(), text: response.results[0].outputText.trimmingCharacters(in: .whitespacesAndNewlines), user: chatModel.name, isError: false, sentTime: Date())
            
        case .j2:
            let response = try backendModel.backend.decode(data) as InvokeAI21Response
            assistantMessage = MessageData(id: UUID(), text: response.completions[0].data.text.trimmingCharacters(in: .whitespacesAndNewlines), user: chatModel.name, isError: false, sentTime: Date())
            
        case .titanImage:
            let response = try backendModel.backend.decode(data) as InvokeTitanImageResponse
            try handleTitanImageResponse(response)
            return // 이미지 응답은 별도로 처리되므로 여기서 반환
            
        case .titanEmbed:
            let response = try backendModel.backend.decode(data) as InvokeTitanEmbedResponse
            assistantMessage = MessageData(id: UUID(), text: response.embedding.map({"\($0)"}).joined(separator: ","), user: chatModel.name, isError: false, sentTime: Date())
            
        case .cohereCommand:
            let response = try backendModel.backend.decode(data) as InvokeCommandResponse
            assistantMessage = MessageData(id: UUID(), text: response.generations[0].text, user: chatModel.name, isError: false, sentTime: Date())
            
        case .cohereEmbed:
            let response = try backendModel.backend.decode(data) as InvokeCohereEmbedResponse
            assistantMessage = MessageData(id: UUID(), text: response.embeddings.map({"\($0)"}).joined(separator: ","), user: chatModel.name, isError: false, sentTime: Date())
            
        case .llama2, .llama3, .mistral:
            let response = try backendModel.backend.decode(data) as InvokeLlama2Response
            assistantMessage = MessageData(id: UUID(), text: response.generation, user: chatModel.name, isError: false, sentTime: Date())
            
        case .jambaInstruct:
            let response = try backendModel.backend.decode(data) as InvokeJambaInstructResponse
            if let firstChoice = response.choices.first {
                assistantMessage = MessageData(
                    id: UUID(),
                    text: firstChoice.message.content.trimmingCharacters(in: .whitespacesAndNewlines),
                    user: chatModel.name,
                    isError: false,
                    sentTime: Date()
                )
            } else {
                // Handle case where there are no choices in the response
                assistantMessage = MessageData(
                    id: UUID(),
                    text: "No response from the model.",
                    user: chatModel.name,
                    isError: true,
                    sentTime: Date()
                )
            }
            
        default:
            assistantMessage = MessageData(id: UUID(), text: "Error: Unable to decode response.", user: "System", isError: false, sentTime: Date())
        }
        
        // 메시지 추가 및 히스토리 업데이트
        messages.append(assistantMessage)
        chatManager.addMessage(assistantMessage, for: chatId)
        
        // 히스토리 업데이트
        var history = chatManager.getHistory(for: chatId)
        if modelType == .llama3 {
            history += "assistant\n\n\(assistantMessage.text)\n\n"
        } else {
            history += "\nAssistant: \(assistantMessage.text)\n"
        }
        chatManager.setHistory(history, for: chatId)
    }
    
    private func handleTitanImageResponse(_ response: InvokeTitanImageResponse) throws {
        let image = response.images[0]
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        let timestamp = formatter.string(from: now)
        let fileName = "\(timestamp).png"
        let tempDir = FileManager.default.homeDirectoryForCurrentUser
        let fileURL = tempDir.appendingPathComponent("Amazon Bedrock Client").appendingPathComponent(fileName)
        
        do {
            try image.write(to: fileURL)
            
            if let encoded = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
                let markdownImage = "![](http://localhost:8080/\(encoded))"
                let imageMessage = MessageData(id: UUID(), text: markdownImage, user: chatModel.name, isError: false, sentTime: Date())
                messages.append(imageMessage)
                chatManager.addMessage(imageMessage, for: chatId)
                
                // 이미지 응답에 대한 히스토리 업데이트
                var history = chatManager.getHistory(for: chatId)
                history += "\nAssistant: [Generated Image]\n"
                chatManager.setHistory(history, for: chatId)
            } else {
                throw NSError(domain: "ImageEncodingError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to encode image filename"])
            }
        } catch {
            throw error
        }
    }
    
    /// Handles Stable Diffusion response.
    private func handleStableDiffusionResponse(_ data: Data) throws {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        let timestamp = formatter.string(from: now)
        let fileName = "\(timestamp).png"
        let tempDir = FileManager.default.homeDirectoryForCurrentUser
        let fileURL = tempDir.appendingPathComponent("Amazon Bedrock Client").appendingPathComponent(fileName)
        
        do {
            try data.write(to: fileURL)
            
            if let encoded = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
                let markdownImage = "![](http://localhost:8080/\(encoded))"
                let imageMessage = MessageData(id: UUID(), text: markdownImage, user: chatModel.name, isError: false, sentTime: Date())
                messages.append(imageMessage)
                chatManager.addMessage(imageMessage, for: chatId)
                
                var history = chatManager.getHistory(for: chatId)
                history += "\nAssistant: [Generated Image]\n"
                chatManager.setHistory(history, for: chatId)
            } else {
                throw NSError(domain: "ImageEncodingError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to encode image filename"])
            }
        } catch {
            throw error
        }
    }
    
    private func createContentBlocks(from message: MessageData) -> [ClaudeMessageRequest.Message.Content] {
        var contentBlocks: [ClaudeMessageRequest.Message.Content] = []
        
        let textContentBlock = ClaudeMessageRequest.Message.Content(type: "text", text: message.text, source: nil)
        contentBlocks.append(textContentBlock)
        
        for base64String in message.imageBase64Strings ?? [] {
            let imageContentBlock = ClaudeMessageRequest.Message.Content(
                type: "image",
                source: ClaudeMessageRequest.Message.Content.ImageSource(
                    mediaType: "image/jpeg", // Assuming JPEG for simplicity
                    data: base64String
                )
            )
            contentBlocks.append(imageContentBlock)
        }
        
        return contentBlocks
    }
    
    /// Encodes an image to Base64.
    func base64EncodeImage(_ image: NSImage, withExtension fileExtension: String) -> (base64String: String?, mediaType: String?) {
        guard let tiffRepresentation = image.tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffRepresentation) else {
            return (nil, nil)
        }
        
        let imageData: Data?
        let mediaType: String
        
        switch fileExtension.lowercased() {
        case "jpg", "jpeg":
            imageData = bitmapImage.representation(using: .jpeg, properties: [:])
            mediaType = "image/jpeg"
        case "png":
            imageData = bitmapImage.representation(using: .png, properties: [:])
            mediaType = "image/png"
        case "webp":
            imageData = nil
            mediaType = "image/webp"
        case "gif":
            imageData = nil
            mediaType = "image/gif"
        default:
            return (nil, nil)
        }
        
        guard let data = imageData else {
            return (nil, nil)
        }
        
        return (data.base64EncodedString(), mediaType)
    }
    
    private static let placeholderMessages = [
        "Start a conversation!",
        "Say something to get started.",
        "Messages will appear here.",
        "Go ahead, say hi!",
        "Ready for your message!",
        "Type something to begin!"
    ]
    
    /// Updates the chat title with a summary of the input.
    func updateChatTitle(with input: String) async {
        let summaryPrompt = """
        Summarize user input <input>\(input)</input> as short as possible. Just in few words without punctuation. It should not be more than 5 words. It will be book title. Do as best as you can. If you don't know how to do summarize, please give me just 'Friendly Chat', but please do summary this without punctuation:
        """
        
        let haikuModelId = "anthropic.claude-3-haiku-20240307-v1:0"
        let message = ClaudeMessageRequest.Message(role: "user", content: [.init(type: "text", text: summaryPrompt)])
        
        do {
            let data = try await backendModel.backend.invokeClaudeModel(withId: haikuModelId, messages: [message])
            let response = try backendModel.backend.decode(data) as ClaudeMessageResponse
            
            if let firstText = response.content.first?.text {
                chatManager.updateChatTitle(for: chatModel.chatId, title: firstText.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        } catch {
            print("Error updating chat title: \(error)")
        }
    }
}
