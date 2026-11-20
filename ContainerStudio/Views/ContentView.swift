//
//  ContentView.swift
//  ContainerStudio
//

import SwiftUI

struct ContentView: View {
    @State private var provider = ContainerAccessProvider.shared

    var body: some View {
        TabView {
            Tab("Главная", systemImage: "house.fill") {
                HomeView(provider: provider)
            }

            Tab("Медиа", systemImage: "photo.stack.fill") {
                MediaGrabberView(provider: provider)
            }

            Tab("Шрифты", systemImage: "textformat") {
                FontManagerView(provider: provider)
            }
        }
        .tint(.orange)
        .onAppear {
            if provider.logs.isEmpty {
                provider.initializeProvider()
            }
        }
    }
}
