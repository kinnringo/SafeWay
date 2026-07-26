allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)

    // ▼ 古いライブラリ(flutter_compass等)の namespace 欠損を自動救済して突破するフック！
    afterEvaluate {
        val android = extensions.findByName("android")
        if (android != null) {
            val namespaceProperty = android.javaClass.getMethod("getNamespace").invoke(android) as? String
            if (namespaceProperty == null) {
                val manifestFile = project.file("src/main/AndroidManifest.xml")
                if (manifestFile.exists()) {
                    val regex = """package="([^"]+)"""".toRegex()
                    val match = regex.find(manifestFile.readText())
                    if (match != null) {
                        val packageName = match.groupValues[1]
                        android.javaClass.getMethod("setNamespace", String::class.java).invoke(android, packageName)
                    }
                }
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
