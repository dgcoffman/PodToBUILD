//
//  ObjcLibrary.swift
//  PodSpecToBUILD
//
//  Created by jerry on 4/19/17.
//  Copyright © 2017 jerry. All rights reserved.
//

import Foundation

/// Law: Names must be valid bazel names; see the spec
protocol BazelTarget: SkylarkConvertible {
    var name: String { get }
}

// https://bazel.build/versions/master/docs/be/objective-c.html#objc_bundle_library
struct ObjcBundleLibrary: BazelTarget {
    let name: String
    let resources: [String]

    func toSkylark() -> SkylarkNode {
        return .functionCall(
            name: "objc_bundle_library",
            arguments: [
                .named(name: "name", value: name.toSkylark()),
                .named(name: "resources",
                       value: resources.toSkylark()),
        ])
    }
}

// https://bazel.build/versions/master/docs/be/general.html#config_setting
struct ConfigSetting: BazelTarget {
    let name: String
    let values: [String: String]
    
    func toSkylark() -> SkylarkNode {
        return .functionCall(
            name: "config_setting",
            arguments: [
		        .named(name: "name", value: name.toSkylark()),
		        .named(name: "values", value: values.toSkylark())
            ])
    }
}

/// rootName -> names -> fixedNames
func fixDependencyNames(rootName: String) -> ([String]) -> [String]  {
    return { $0.map{ depName in
        // Build up dependencies. Versions are ignored!
        // When a given dependency is locally speced, it should
        // Match the PodName i.e. PINCache/Core
        let results = depName.components(separatedBy: "/")
        if results.count > 1 && results[0] == rootName {
            let join = results[1 ... results.count - 1].joined(separator: "/")
            return ":\(rootName)_\(ObjcLibrary.bazelLabel(fromString: join))"
        } else {
            return "@\(depName)//:\(depName)"
        }
    } }
}


// ObjcLibrary is an intermediate rep of an objc library
struct ObjcLibrary: BazelTarget {
    var name: String
    var externalName: String
    var sourceFiles: [String]
    var headers: [String]
    var sdkFrameworks: AttrSet<[String]>
    var weakSdkFrameworks: AttrSet<[String]>
    var sdkDylibs: AttrSet<[String]>
    var deps: AttrSet<[String]>
    var copts: AttrSet<[String]>
    var bundles: AttrSet<[String]>
    var excludedSource = [String]()
    static let xcconfigTransformer = XCConfigTransformer.defaultTransformer()

    init(name: String,
        externalName: String,
        sourceFiles: [String],
        headers: [String],
        sdkFrameworks: AttrSet<[String]>,
        weakSdkFrameworks: AttrSet<[String]>,
        sdkDylibs: AttrSet<[String]>,
        deps: AttrSet<[String]>,
        copts: AttrSet<[String]>,
        bundles: AttrSet<[String]>,
        excludedSource: [String] = []) {
        self.name = name
        self.externalName = externalName
        self.sourceFiles = sourceFiles
        self.headers = headers
        self.sdkFrameworks = sdkFrameworks
        self.weakSdkFrameworks = weakSdkFrameworks
        self.sdkDylibs = sdkDylibs
        self.deps = deps
        self.copts = copts
        self.bundles = bundles
        self.excludedSource = excludedSource
    }

    static func bazelLabel(fromString string: String) -> String {
        return string.replacingOccurrences(of: "\\/", with: "_").replacingOccurrences(of: "-", with: "_")
    }
    
    
    init(rootName: String, spec: PodSpec, extraDeps: [String] = []) {
        let headersAndSourcesInfo = headersAndSources(fromSourceFilePatterns: spec.sourceFiles)
        
        let xcconfigFlags =
            ObjcLibrary.xcconfigTransformer.compilerFlags(forXCConfig: spec.podTargetXcconfig) +
            ObjcLibrary.xcconfigTransformer.compilerFlags(forXCConfig: spec.userTargetXcconfig) +
            ObjcLibrary.xcconfigTransformer.compilerFlags(forXCConfig: spec.xcconfig)
        
        self.name = spec.name == rootName ?
                rootName : ObjcLibrary.bazelLabel(fromString: "\(rootName)_\(spec.name)")
        self.externalName = rootName
        self.sourceFiles = headersAndSourcesInfo.sourceFiles
        self.headers = headersAndSourcesInfo.headers
        self.sdkFrameworks = spec ^* liftToAttr(PodSpec.lens.frameworks)
        self.weakSdkFrameworks = spec ^* liftToAttr(PodSpec.lens.weakFrameworks)
        self.sdkDylibs = spec ^* liftToAttr(PodSpec.lens.libraries)
        self.deps = AttrSet(basic: extraDeps.map{ ":\($0)" }) <> (spec ^* liftToAttr(PodSpec.lens.dependencies .. ReadonlyLens(fixDependencyNames(rootName: rootName))))
        self.copts = AttrSet(basic: xcconfigFlags) <> (spec ^* liftToAttr(PodSpec.lens.compilerFlags))
        self.bundles = spec ^* liftToAttr(PodSpec.lens.resourceBundles .. ReadonlyLens { $0.map { k, _ in ":\(spec.name)-\(k)" } })
        self.excludedSource = getCompiledSource(fromPatterns: spec.excludeFiles)
    }
    
    // MARK: - Bazel Rendering

    func toSkylark() -> SkylarkNode {
        let lib = self
        let nameArgument = SkylarkFunctionArgument.named(name: "name", value: .string(lib.name))

        var inlineSkylark = [SkylarkNode]()
        var libArguments = [SkylarkFunctionArgument]()

        libArguments.append(nameArgument)
        if lib.sourceFiles.count > 0 {
            // Glob all of the source files and exclude excluded sources
            var globArguments = [SkylarkFunctionArgument.basic(lib.sourceFiles.toSkylark())]
            if lib.excludedSource.count > 0 {
                globArguments.append(.named(
                    name: "exclude",
                    value: excludedSource.toSkylark()
                ))
            }
            libArguments.append(.named(
                name: "srcs",
                value: .functionCall(name: "glob", arguments: globArguments)
            ))
        }

        if lib.headers.count > 0 {
            // Generate header logic
            // source_headers = glob(["Source/*.h"])
            // extra_headers = glob(["bazel_support/Headers/Public/**/*.h"])
            // hdrs = source_headers + extra_headers

            // HACK! There is no assignment in Skylark Imp
            inlineSkylark.append(.functionCall(
                name: "\(lib.name)_source_headers = glob",
                arguments: [.basic(lib.headers.toSkylark())]
            ))

            // HACK! There is no assignment in Skylark Imp
            inlineSkylark.append(.functionCall(
                name: "\(lib.name)_extra_headers = glob",
                arguments: [.basic(["bazel_support/Headers/Public/**/*.h"].toSkylark())]
            ))

            inlineSkylark.append(.skylark(
                "\(lib.name)_headers = \(lib.name)_source_headers + \(lib.name)_extra_headers"
            ))

            libArguments.append(.named(
                name: "hdrs",
                value: .skylark("\(lib.name)_headers")
            ))

             libArguments.append(.named(
                name: "pch",
                value:.functionCall(
                    // Call internal function to find a PCH.
                    // @see workspace.bzl
                    name: "pch_with_name_hint",
                    arguments: [.basic(.string(lib.externalName))]
                )
            ))

            // Include the public headers which are symlinked in
            // All includes are bubbled up automatically
            libArguments.append(.named(
                name: "includes",
                value: [
                    "bazel_support/Headers/Public/",
                    "bazel_support/Headers/Public/\(externalName)/",
                ].toSkylark()
            ))
        }
        if !lib.sdkFrameworks.isEmpty {
            libArguments.append(.named(
                name: "sdk_frameworks",
                value: lib.sdkFrameworks.toSkylark()
            ))
        }

        if !lib.weakSdkFrameworks.isEmpty {
            libArguments.append(.named(
                name: "weak_sdk_frameworks",
                value: lib.weakSdkFrameworks.toSkylark()
            ))
        }

        if !lib.sdkDylibs.isEmpty {
            libArguments.append(.named(
                name: "sdk_dylibs",
                value: lib.sdkDylibs.toSkylark()
            ))
        }

        if !lib.deps.isEmpty {
            libArguments.append(.named(
                name: "deps",
                value: lib.deps.toSkylark()
            ))
        }
        if !lib.copts.isEmpty {
            libArguments.append(.named(
                name: "copts",
                value: lib.copts.toSkylark()
            ))
        }

        if !lib.bundles.isEmpty {
            libArguments.append(.named(name: "bundles",
                                       value: bundles.toSkylark()))
        }
        libArguments.append(.named(
            name: "visibility",
            value: ["//visibility:public"].toSkylark()
        ))
        return .lines(inlineSkylark + [.functionCall(name: "objc_library", arguments: libArguments)])
    }
}

// This is domain specific to bazel. Bazel's "glob" can't support wild cards so add
// multiple entries instead of {m, cpp}
// see above for further docs
func getCompiledSource(fromPatterns patterns: [String]) -> [String] {
    var sourceFiles = [String]()
    for sourceFilePattern in patterns {
        if let impl = pattern(fromPattern: sourceFilePattern, includingFileType: "m") {
            sourceFiles.append(impl)
        }
        if let impl = pattern(fromPattern: sourceFilePattern, includingFileType: "mm") {
            sourceFiles.append(impl)
        }
        if let impl = pattern(fromPattern: sourceFilePattern, includingFileType: "cpp") {
            sourceFiles.append(impl)
        }
        if let impl = pattern(fromPattern: sourceFilePattern, includingFileType: "c") {
            sourceFiles.append(impl)
        }
    }
    return sourceFiles
}