import SwiftUI

/// Pantalla principal con la barra inferior «Artículos» / «Blogs».
struct RootView: View {
    enum Tab: String, Hashable { case articles, blogs }

    @SceneStorage("selectedTab") private var selection: Tab = .articles

    var body: some View {
        TabView(selection: $selection) {
            LibraryView()
                .tabItem { Label("Artículos", systemImage: "doc.richtext") }
                .tag(Tab.articles)
            BlogsView()
                .tabItem { Label("Blogs", systemImage: "books.vertical") }
                .tag(Tab.blogs)
        }
    }
}
