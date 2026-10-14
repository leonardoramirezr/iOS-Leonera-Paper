import SwiftUI

@main
struct LeoneraPaperApp: App {
    @State private var library: Library
    @State private var drive: DriveSync
    @State private var dictionary = DictionaryService()
    @State private var preferences = ReaderPreferences()
    @State private var blogs = BlogStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let library = Library()
        let drive = DriveSync()
        library.drive = drive
        _library = State(initialValue: library)
        _drive = State(initialValue: drive)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(drive)
                .environment(dictionary)
                .environment(preferences)
                .environment(blogs)
                .onOpenURL { url in
                    library.handleIncoming(url)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        library.drainSharedQueue()
                    }
                }
                .task {
                    library.drainSharedQueue()
                }
        }
    }
}
