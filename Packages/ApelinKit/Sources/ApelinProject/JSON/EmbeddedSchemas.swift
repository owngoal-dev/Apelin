// Generated from Documents/Schemas/*.schema.json; do not edit.
// ApelinProjectTests fails when this file and the schemas differ. Regenerate with:
//   Packages/ApelinKit/Scripts/embed-schemas.py

enum EmbeddedSchemas {
    static let project = #"""
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://owngoal-dev.github.io/Apelin/schemas/apelin-project-1.json",
  "title": "Apelin project description, version 1",
  "description": "apelin-project.json at the root of ~/Documents/wiki.qaq.apelin/Projects/<name>/. The one build entry the UI, the agent and apelin-build all read. Documents/Schemas/README.md is the prose specification; it also fixes which members form the build and packaging descriptions whose digests drive Confirm-mode approval.",
  "type": "object",
  "additionalProperties": false,
  "required": [
    "schemaVersion",
    "projectID",
    "kind",
    "template",
    "environment",
    "language",
    "deploymentTarget",
    "architectures",
    "configurations",
    "products",
    "build",
    "package"
  ],
  "properties": {
    "schemaVersion": { "const": 1 },
    "displayName": { "type": "string", "minLength": 1, "maxLength": 80 },
    "autoName": { "type": "boolean" },
    "projectID": {
      "description": "Stable identity. Renaming the project folder never changes it; approvals are bound to it.",
      "$ref": "#/$defs/uuid"
    },
    "kind": { "enum": ["app", "tweak", "cli", "preferences"] },
    "template": { "$ref": "#/$defs/templateSource" },
    "environment": {
      "type": "object",
      "additionalProperties": false,
      "required": ["toolchain", "sdk"],
      "properties": {
        "toolchain": { "$ref": "#/$defs/binding" },
        "sdk": { "$ref": "#/$defs/binding" }
      }
    },
    "language": {
      "description": "The main language. A product may still contain C sources beside Objective-C ones; Swift and C-family sources are never mixed in one product in v1.",
      "enum": ["c", "objc", "swift"]
    },
    "deploymentTarget": { "$ref": "#/$defs/iosVersion" },
    "architectures": {
      "description": "Slices to build, per bootstrap. The keys present are the bootstraps the project packages for.",
      "type": "object",
      "additionalProperties": false,
      "minProperties": 1,
      "properties": {
        "rootless": { "$ref": "#/$defs/archList" },
        "roothide": { "$ref": "#/$defs/archList" }
      }
    },
    "configurations": {
      "type": "object",
      "additionalProperties": false,
      "required": ["Debug", "Release"],
      "properties": {
        "Debug": { "$ref": "#/$defs/configuration" },
        "Release": { "$ref": "#/$defs/configuration" }
      }
    },
    "products": {
      "type": "array",
      "minItems": 1,
      "maxItems": 8,
      "items": { "$ref": "#/$defs/product" }
    },
    "build": {
      "type": "object",
      "additionalProperties": false,
      "required": ["steps"],
      "properties": {
        "steps": {
          "type": "array",
          "minItems": 1,
          "maxItems": 128,
          "items": { "$ref": "#/$defs/step" }
        }
      }
    },
    "package": { "$ref": "#/$defs/package" }
  },
  "allOf": [
    {
      "if": { "properties": { "kind": { "const": "tweak" } } },
      "then": {
        "properties": {
          "package": { "required": ["tweakFilter"] },
          "products": { "contains": { "properties": { "type": { "const": "dylib" } }, "required": ["type"] } }
        }
      },
      "else": {
        "properties": { "package": { "not": { "required": ["tweakFilter"] } } }
      }
    },
    {
      "if": { "properties": { "kind": { "const": "app" } } },
      "then": {
        "properties": {
          "products": { "contains": { "properties": { "type": { "const": "app" } }, "required": ["type"] } }
        }
      }
    },
    {
      "if": { "properties": { "kind": { "const": "cli" } } },
      "then": {
        "properties": {
          "products": { "contains": { "properties": { "type": { "const": "executable" } }, "required": ["type"] } }
        }
      }
    },
    {
      "if": { "properties": { "kind": { "const": "preferences" } } },
      "then": {
        "properties": {
          "products": { "contains": { "properties": { "type": { "const": "bundle" } }, "required": ["type"] } }
        }
      }
    }
  ],
  "$defs": {
    "uuid": {
      "type": "string",
      "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
    },
    "digest": {
      "description": "sha256: followed by 64 lowercase hex digits.",
      "type": "string",
      "pattern": "^sha256:[0-9a-f]{64}$"
    },
    "reverseDNS": {
      "type": "string",
      "minLength": 3,
      "maxLength": 128,
      "pattern": "^[a-z0-9][a-z0-9-]*(\\.[a-z0-9][a-z0-9-]*)+$"
    },
    "bundleID": {
      "type": "string",
      "minLength": 3,
      "maxLength": 128,
      "pattern": "^[A-Za-z0-9][A-Za-z0-9-]*(\\.[A-Za-z0-9][A-Za-z0-9-]*)+$"
    },
    "packageID": {
      "description": "A Debian package name.",
      "type": "string",
      "minLength": 2,
      "maxLength": 128,
      "pattern": "^[a-z0-9][a-z0-9+.-]+$"
    },
    "packageVersion": {
      "type": "string",
      "maxLength": 64,
      "pattern": "^([0-9]+:)?[0-9][0-9A-Za-z.+~-]*$"
    },
    "iosVersion": {
      "description": "16.0 or later: the app's own floor.",
      "type": "string",
      "pattern": "^(1[6-9]|[2-9][0-9])\\.[0-9]{1,2}(\\.[0-9]{1,2})?$"
    },
    "identifier": {
      "type": "string",
      "pattern": "^[A-Za-z_][A-Za-z0-9_]{0,63}$"
    },
    "relativePath": {
      "description": "A path inside the project. No component may be empty or start with '.', so '.' and '..' cannot be spelled. projectCheck still realpaths it and refuses anything that resolves outside the project root.",
      "type": "string",
      "maxLength": 1024,
      "pattern": "^[A-Za-z0-9_+@][A-Za-z0-9._+@ -]*(/[A-Za-z0-9_+@][A-Za-z0-9._+@ -]*)*$"
    },
    "relativeGlob": {
      "description": "A relativePath that may use '*' (within a component), '**' (any depth) and '?'.",
      "type": "string",
      "maxLength": 1024,
      "pattern": "^[A-Za-z0-9_+@*?][A-Za-z0-9._+@ *?-]*(/[A-Za-z0-9_+@*?][A-Za-z0-9._+@ *?-]*)*$"
    },
    "logicalPath": {
      "description": "An install path as the package sees it, rooted at the bootstrap. The packager maps it per bootstrap (@PREFIX@ = '' on roothide, '/var/jb' on rootless); the project never stores a jbroot path.",
      "type": "string",
      "maxLength": 1024,
      "pattern": "^/(Applications|Library|usr|etc)(/[A-Za-z0-9_+@][A-Za-z0-9._+@ -]*)+$"
    },
    "flag": {
      "description": "One argument handed to clang, ld or swiftc as its own argv element. Never parsed by a shell.",
      "type": "string",
      "minLength": 2,
      "maxLength": 1024,
      "pattern": "^-[^\\u0000\\n\\r]+$"
    },
    "relation": {
      "description": "One Depends-style relation, alternatives joined with ' | '.",
      "type": "string",
      "maxLength": 512,
      "pattern": "^[a-z0-9][a-z0-9+.-]+( \\((<<|<=|=|>=|>>) [0-9A-Za-z.+:~-]+\\))?( \\| [a-z0-9][a-z0-9+.-]+( \\((<<|<=|=|>=|>>) [0-9A-Za-z.+:~-]+\\))?)*$"
    },
    "relationList": {
      "type": "array",
      "uniqueItems": true,
      "maxItems": 64,
      "items": { "$ref": "#/$defs/relation" }
    },
    "singleLine": {
      "type": "string",
      "minLength": 1,
      "maxLength": 200,
      "pattern": "^[^\\u0000-\\u001f\\u007f]+$"
    },
    "archList": {
      "type": "array",
      "minItems": 1,
      "uniqueItems": true,
      "items": { "enum": ["arm64", "arm64e"] }
    },
    "binding": {
      "description": "A registered toolchain or SDK, pinned by the id it was registered under and the content digest recorded at registration. Changing either is an explicit operation.",
      "type": "object",
      "additionalProperties": false,
      "required": ["id", "digest"],
      "properties": {
        "id": {
          "type": "string",
          "pattern": "^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$"
        },
        "digest": { "$ref": "#/$defs/digest" }
      }
    },
    "templateSource": {
      "description": "Where the project came from. The host's Confirm-mode baseline is the description of the project as this template generated it.",
      "type": "object",
      "additionalProperties": false,
      "required": ["extensionID", "templateID", "version", "digest"],
      "properties": {
        "extensionID": { "$ref": "#/$defs/reverseDNS" },
        "templateID": {
          "type": "string",
          "pattern": "^[a-z][a-z0-9-]{0,63}$"
        },
        "version": {
          "description": "The extension version that carried the template.",
          "$ref": "#/$defs/packageVersion"
        },
        "digest": {
          "description": "The template digest from the extension manifest (README ▸ Template digest).",
          "$ref": "#/$defs/digest"
        }
      }
    },
    "configuration": {
      "type": "object",
      "additionalProperties": false,
      "required": ["optimization", "debugInfo"],
      "properties": {
        "optimization": { "enum": ["0", "1", "2", "3", "s", "z"] },
        "debugInfo": { "type": "boolean" },
        "defines": {
          "description": "Preprocessor definitions. The APELIN_ prefix is reserved for what the build injects.",
          "type": "object",
          "maxProperties": 64,
          "propertyNames": {
            "pattern": "^(?!APELIN_)[A-Za-z_][A-Za-z0-9_]{0,63}$"
          },
          "additionalProperties": {
            "type": "string",
            "maxLength": 256,
            "pattern": "^[^\\u0000\\n\\r]*$"
          }
        },
        "cFlags": { "type": "array", "maxItems": 64, "items": { "$ref": "#/$defs/flag" } },
        "swiftFlags": { "type": "array", "maxItems": 64, "items": { "$ref": "#/$defs/flag" } },
        "linkFlags": { "type": "array", "maxItems": 64, "items": { "$ref": "#/$defs/flag" } }
      }
    },
    "extensionSupport": {
      "description": "A support component an installed development extension declares (headers, link stubs, rpaths). Resolved through the extension's manifest, never by a path the project spells.",
      "type": "object",
      "additionalProperties": false,
      "required": ["extension", "component"],
      "properties": {
        "extension": { "$ref": "#/$defs/reverseDNS" },
        "component": {
          "type": "string",
          "pattern": "^[a-z][a-z0-9-]{0,63}$"
        }
      }
    },
    "product": {
      "type": "object",
      "additionalProperties": false,
      "required": ["id", "type", "name", "sources"],
      "properties": {
        "id": {
          "type": "string",
          "pattern": "^[a-z][a-z0-9-]{0,31}$"
        },
        "type": { "enum": ["app", "dylib", "bundle", "executable"] },
        "name": {
          "description": "The Mach-O file name, and the bundle name without its extension for app and bundle.",
          "type": "string",
          "pattern": "^[A-Za-z0-9_][A-Za-z0-9_.+-]{0,63}$"
        },
        "sources": {
          "type": "array",
          "minItems": 1,
          "maxItems": 64,
          "items": { "$ref": "#/$defs/relativeGlob" }
        },
        "headerSearchPaths": {
          "type": "array",
          "maxItems": 32,
          "items": { "$ref": "#/$defs/relativePath" }
        },
        "resources": {
          "description": "Files bundle-resources copies into an app or bundle, flattened to their file names. A .plist is written as XML after a lint.",
          "type": "array",
          "maxItems": 64,
          "items": { "$ref": "#/$defs/relativeGlob" }
        },
        "infoPlist": { "$ref": "#/$defs/relativePath" },
        "entitlements": { "$ref": "#/$defs/relativePath" },
        "installName": {
          "type": "string",
          "maxLength": 512,
          "pattern": "^(@rpath|@loader_path|@executable_path|/)[^\\u0000\\n\\r]*$"
        },
        "objcARC": { "type": "boolean" },
        "frameworks": {
          "type": "array",
          "uniqueItems": true,
          "maxItems": 64,
          "items": { "$ref": "#/$defs/identifier" }
        },
        "weakFrameworks": {
          "type": "array",
          "uniqueItems": true,
          "maxItems": 64,
          "items": { "$ref": "#/$defs/identifier" }
        },
        "libraries": {
          "description": "-l names, resolved in the SDK, the project's librarySearchPaths and the extension support stubs.",
          "type": "array",
          "uniqueItems": true,
          "maxItems": 64,
          "items": { "type": "string", "pattern": "^[A-Za-z0-9_][A-Za-z0-9_+.-]{0,63}$" }
        },
        "frameworkSearchPaths": {
          "type": "array",
          "maxItems": 16,
          "items": { "$ref": "#/$defs/relativePath" }
        },
        "librarySearchPaths": {
          "type": "array",
          "maxItems": 16,
          "items": { "$ref": "#/$defs/relativePath" }
        },
        "extensionSupport": {
          "type": "array",
          "maxItems": 8,
          "items": { "$ref": "#/$defs/extensionSupport" }
        }
      },
      "allOf": [
        {
          "if": { "properties": { "type": { "enum": ["app", "bundle"] } } },
          "then": { "required": ["infoPlist"] },
          "else": { "not": { "anyOf": [{ "required": ["infoPlist"] }, { "required": ["resources"] }] } }
        },
        {
          "if": { "properties": { "type": { "const": "dylib" } } },
          "else": { "not": { "required": ["installName"] } }
        }
      ]
    },
    "step": {
      "description": "One typed build step. There is no free shell string: the only step that runs project-supplied code is 'script', which always asks for approval under Confirm the first time its build description digest is seen.",
      "type": "object",
      "required": ["type"],
      "properties": {
        "type": {
          "enum": ["compile", "link", "bundle-resources", "lipo", "dsym", "strip", "sign", "script"]
        }
      },
      "oneOf": [
        { "$ref": "#/$defs/stepCompile" },
        { "$ref": "#/$defs/stepLink" },
        { "$ref": "#/$defs/stepBundleResources" },
        { "$ref": "#/$defs/stepLipo" },
        { "$ref": "#/$defs/stepDsym" },
        { "$ref": "#/$defs/stepStrip" },
        { "$ref": "#/$defs/stepSign" },
        { "$ref": "#/$defs/stepScript" }
      ]
    },
    "productRef": {
      "type": "string",
      "pattern": "^[a-z][a-z0-9-]{0,31}$"
    },
    "stepCompile": {
      "description": "Every source of the product, once per architecture, to an object file that is kept for dsym.",
      "type": "object",
      "additionalProperties": false,
      "required": ["type", "product"],
      "properties": {
        "type": { "const": "compile" },
        "product": { "$ref": "#/$defs/productRef" },
        "flags": { "type": "array", "maxItems": 32, "items": { "$ref": "#/$defs/flag" } }
      }
    },
    "stepLink": {
      "description": "One Mach-O per architecture: MH_EXECUTE for app and executable, MH_DYLIB for dylib, MH_BUNDLE for bundle.",
      "type": "object",
      "additionalProperties": false,
      "required": ["type", "product"],
      "properties": {
        "type": { "const": "link" },
        "product": { "$ref": "#/$defs/productRef" },
        "flags": { "type": "array", "maxItems": 32, "items": { "$ref": "#/$defs/flag" } }
      }
    },
    "stepBundleResources": {
      "description": "Assemble the .app or .bundle directory: the product's Info.plist, with CFBundleExecutable, CFBundleShortVersionString, CFBundleVersion and MinimumOSVersion set by the build, and its resources.",
      "type": "object",
      "additionalProperties": false,
      "required": ["type", "product"],
      "properties": {
        "type": { "const": "bundle-resources" },
        "product": { "$ref": "#/$defs/productRef" }
      }
    },
    "stepLipo": {
      "type": "object",
      "additionalProperties": false,
      "required": ["type", "product"],
      "properties": {
        "type": { "const": "lipo" },
        "product": { "$ref": "#/$defs/productRef" }
      }
    },
    "stepDsym": {
      "description": "dsymutil on the merged Mach-O while the objects still exist; fails when the dSYM has no __debug_info or its UUIDs differ from the product's.",
      "type": "object",
      "additionalProperties": false,
      "required": ["type", "product"],
      "properties": {
        "type": { "const": "dsym" },
        "product": { "$ref": "#/$defs/productRef" }
      }
    },
    "stepStrip": {
      "type": "object",
      "additionalProperties": false,
      "required": ["type", "product"],
      "properties": {
        "type": { "const": "strip" },
        "product": { "$ref": "#/$defs/productRef" },
        "style": {
          "description": "debug: strip -S. non-global: strip -x (default). Exported symbols always stay.",
          "enum": ["debug", "non-global"]
        }
      }
    },
    "stepSign": {
      "description": "Ad-hoc signature with the product's entitlements (or none). Must be the last step that touches its product.",
      "type": "object",
      "additionalProperties": false,
      "required": ["type", "product"],
      "properties": {
        "type": { "const": "sign" },
        "product": { "$ref": "#/$defs/productRef" },
        "identity": { "const": "adhoc" }
      }
    },
    "stepScript": {
      "description": "A script file in the project, run as mobile in the project root with argv [interpreter, file, arguments...]. Never a command string.",
      "type": "object",
      "additionalProperties": false,
      "required": ["type", "id", "interpreter", "file", "requiresApproval"],
      "properties": {
        "type": { "const": "script" },
        "id": {
          "type": "string",
          "pattern": "^[a-z][a-z0-9-]{0,31}$"
        },
        "interpreter": { "enum": ["sh", "bash", "zsh", "python3", "perl"] },
        "file": { "$ref": "#/$defs/relativePath" },
        "arguments": {
          "type": "array",
          "maxItems": 64,
          "items": { "type": "string", "maxLength": 1024, "pattern": "^[^\\u0000]*$" }
        },
        "inputs": { "type": "array", "maxItems": 64, "items": { "$ref": "#/$defs/relativeGlob" } },
        "outputs": { "type": "array", "maxItems": 64, "items": { "$ref": "#/$defs/relativeGlob" } },
        "requiresApproval": {
          "description": "Always true: spelled out so a reader of the file sees that this step is reviewed.",
          "const": true
        }
      }
    },
    "layoutEntry": {
      "type": "object",
      "required": ["path"],
      "oneOf": [
        {
          "description": "A built product: the merged, signed Mach-O, or the whole .app/.bundle directory.",
          "type": "object",
          "additionalProperties": false,
          "required": ["path", "product"],
          "properties": {
            "path": { "$ref": "#/$defs/logicalPath" },
            "product": { "$ref": "#/$defs/productRef" },
            "mode": { "enum": ["0755", "0644"] }
          }
        },
        {
          "description": "A project file copied verbatim, or with @PREFIX@ and @ROOTFS@ substituted per bootstrap.",
          "type": "object",
          "additionalProperties": false,
          "required": ["path", "file"],
          "properties": {
            "path": { "$ref": "#/$defs/logicalPath" },
            "file": { "$ref": "#/$defs/relativePath" },
            "mode": { "enum": ["0755", "0644"] },
            "substitutePrefix": { "type": "boolean" }
          }
        }
      ]
    },
    "tweakFilter": {
      "description": "Written by the packager as <dylib basename>.plist beside the dylib's layout path, as an XML plist with a single Filter dictionary.",
      "type": "object",
      "additionalProperties": false,
      "required": ["dylib"],
      "minProperties": 2,
      "properties": {
        "dylib": { "$ref": "#/$defs/productRef" },
        "bundles": {
          "type": "array",
          "uniqueItems": true,
          "minItems": 1,
          "maxItems": 32,
          "items": { "$ref": "#/$defs/bundleID" }
        },
        "executables": {
          "type": "array",
          "uniqueItems": true,
          "minItems": 1,
          "maxItems": 32,
          "items": { "type": "string", "pattern": "^[A-Za-z0-9_][A-Za-z0-9_.+ -]{0,63}$" }
        },
        "classes": {
          "type": "array",
          "uniqueItems": true,
          "minItems": 1,
          "maxItems": 32,
          "items": { "$ref": "#/$defs/identifier" }
        }
      }
    },
    "package": {
      "type": "object",
      "additionalProperties": false,
      "required": ["id", "name", "version", "description", "author", "section", "layout"],
      "properties": {
        "id": { "$ref": "#/$defs/packageID" },
        "name": { "$ref": "#/$defs/singleLine" },
        "version": {
          "description": "Not part of the packaging description: bumping it never asks for review.",
          "$ref": "#/$defs/packageVersion"
        },
        "description": { "$ref": "#/$defs/singleLine" },
        "longDescription": {
          "type": "array",
          "maxItems": 32,
          "items": { "type": "string", "maxLength": 200, "pattern": "^[^\\u0000-\\u001f\\u007f]*$" }
        },
        "icon": {
          "description": "The control's Icon: the image a package manager shows beside the package, not the app's own icon. An https URL in printable ASCII, so no space or control character and at most 2048 bytes. Templates write their extension's icon on Apelin's Pages.",
          "type": "string",
          "maxLength": 2048,
          "pattern": "^https://[A-Za-z0-9][!-~]*$"
        },
        "depiction": {
          "description": "The control's Depiction: the web page a package manager opens for the package. An https URL in printable ASCII, so no space or control character and at most 2048 bytes. Nothing is written without it.",
          "type": "string",
          "maxLength": 2048,
          "pattern": "^https://[A-Za-z0-9][!-~]*$"
        },
        "sileoDepiction": {
          "description": "The control's SileoDepiction: the native depiction, a JSON document Sileo and Irisin draw themselves, which is where a package's changelog tab comes from. An https URL of the same form as depiction. Nothing is written without it.",
          "type": "string",
          "maxLength": 2048,
          "pattern": "^https://[A-Za-z0-9][!-~]*$"
        },
        "author": { "$ref": "#/$defs/singleLine" },
        "maintainer": { "$ref": "#/$defs/singleLine" },
        "section": {
          "enum": ["Tweaks", "Utilities", "Development", "System", "Applications", "Addons"]
        },
        "depends": { "$ref": "#/$defs/relationList" },
        "dependsByBootstrap": {
          "type": "object",
          "additionalProperties": false,
          "properties": {
            "rootless": { "$ref": "#/$defs/relationList" },
            "roothide": { "$ref": "#/$defs/relationList" }
          }
        },
        "recommends": { "$ref": "#/$defs/relationList" },
        "suggests": { "$ref": "#/$defs/relationList" },
        "conflicts": { "$ref": "#/$defs/relationList" },
        "breaks": { "$ref": "#/$defs/relationList" },
        "replaces": { "$ref": "#/$defs/relationList" },
        "provides": { "$ref": "#/$defs/relationList" },
        "layout": {
          "type": "array",
          "minItems": 1,
          "maxItems": 64,
          "items": { "$ref": "#/$defs/layoutEntry" }
        },
        "maintainerScripts": {
          "description": "Shown in full on the install card. @PREFIX@ and @ROOTFS@ are substituted; nothing else is.",
          "type": "object",
          "additionalProperties": false,
          "minProperties": 1,
          "properties": {
            "preinst": { "$ref": "#/$defs/relativePath" },
            "postinst": { "$ref": "#/$defs/relativePath" },
            "prerm": { "$ref": "#/$defs/relativePath" },
            "postrm": { "$ref": "#/$defs/relativePath" }
          }
        },
        "tweakFilter": { "$ref": "#/$defs/tweakFilter" }
      }
    }
  }
}
"""#

    static let manifest = #"""
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://owngoal-dev.github.io/Apelin/schemas/extension-manifest-1.json",
  "title": "Apelin development extension manifest, version 1",
  "description": "<install-root>/usr/share/apelin/development/<id>/manifest.json. Read, never executed: nothing here names a program the app or host runs. Each manifest is validated on its own; a bad one isolates that extension only. Documents/Schemas/README.md is the prose specification.",
  "type": "object",
  "additionalProperties": false,
  "required": [
    "schemaVersion",
    "id",
    "version",
    "kind",
    "displayName",
    "summary",
    "apelinCompatibility",
    "requirements",
    "templates",
    "provenance",
    "licenses"
  ],
  "properties": {
    "schemaVersion": { "const": 1 },
    "id": {
      "description": "Equal to the Debian package id and to the directory name under usr/share/apelin/development/.",
      "$ref": "#/$defs/reverseDNS"
    },
    "version": {
      "description": "Equal to the package Version. Recorded in every project made from this extension.",
      "$ref": "#/$defs/version"
    },
    "kind": { "enum": ["app", "tweak", "cli", "preferences"] },
    "displayName": { "$ref": "#/$defs/text" },
    "summary": { "$ref": "#/$defs/text" },
    "apelinCompatibility": {
      "type": "object",
      "additionalProperties": false,
      "required": ["minimumAppVersion", "projectSchemaVersions", "manifestSchemaVersion"],
      "properties": {
        "minimumAppVersion": { "$ref": "#/$defs/version" },
        "projectSchemaVersions": {
          "description": "apelin-project.json schema versions the templates produce.",
          "type": "array",
          "minItems": 1,
          "uniqueItems": true,
          "items": { "type": "integer", "minimum": 1, "maximum": 1000 }
        },
        "manifestSchemaVersion": { "const": 1 }
      }
    },
    "requirements": {
      "type": "object",
      "additionalProperties": false,
      "required": ["toolchainComponents", "languages", "bootstraps", "architectures"],
      "properties": {
        "toolchainComponents": {
          "type": "array",
          "minItems": 1,
          "uniqueItems": true,
          "items": { "enum": ["c-family", "swift"] }
        },
        "languages": {
          "type": "array",
          "minItems": 1,
          "uniqueItems": true,
          "items": { "enum": ["c", "objc", "swift"] }
        },
        "sdkFrameworks": {
          "description": "Public SDK frameworks the templates link. Private frameworks come from support stubs, never assumed in the SDK.",
          "type": "array",
          "uniqueItems": true,
          "items": { "$ref": "#/$defs/identifier" }
        },
        "bootstraps": {
          "type": "array",
          "minItems": 1,
          "uniqueItems": true,
          "items": { "enum": ["rootless", "roothide"] }
        },
        "architectures": {
          "type": "object",
          "additionalProperties": false,
          "minProperties": 1,
          "properties": {
            "rootless": { "$ref": "#/$defs/archList" },
            "roothide": { "$ref": "#/$defs/archList" }
          }
        },
        "runtimeDependencies": {
          "description": "What a package built from these templates needs installed on the device, per bootstrap, as Debian relations (virtual package names, never one implementation).",
          "$ref": "#/$defs/perBootstrapRelations"
        }
      }
    },
    "support": {
      "description": "Headers and link stubs the extension ships for its templates. A project names a component with extensionSupport; the build adds its include and library paths.",
      "type": "object",
      "maxProperties": 8,
      "propertyNames": { "pattern": "^[a-z][a-z0-9-]{0,63}$" },
      "additionalProperties": { "$ref": "#/$defs/supportComponent" }
    },
    "templates": {
      "type": "array",
      "minItems": 1,
      "maxItems": 32,
      "items": { "$ref": "#/$defs/template" }
    },
    "provenance": {
      "type": "array",
      "minItems": 1,
      "items": { "$ref": "#/$defs/provenanceEntry" }
    },
    "licenses": {
      "type": "array",
      "minItems": 1,
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["path", "spdx", "covers"],
        "properties": {
          "path": { "$ref": "#/$defs/relativePath" },
          "spdx": { "enum": ["MIT", "BSD-2-Clause", "BSD-3-Clause", "Apache-2.0", "0BSD", "MIT-0"] },
          "covers": {
            "type": "array",
            "minItems": 1,
            "items": { "$ref": "#/$defs/scope" }
          }
        }
      }
    }
  },
  "$defs": {
    "reverseDNS": {
      "type": "string",
      "minLength": 3,
      "maxLength": 128,
      "pattern": "^[a-z0-9][a-z0-9-]*(\\.[a-z0-9][a-z0-9-]*)+$"
    },
    "version": {
      "type": "string",
      "maxLength": 64,
      "pattern": "^[0-9]+\\.[0-9]+\\.[0-9]+([~+-][0-9A-Za-z.]+)?$"
    },
    "digest": {
      "type": "string",
      "pattern": "^sha256:[0-9a-f]{64}$"
    },
    "identifier": {
      "type": "string",
      "pattern": "^[A-Za-z_][A-Za-z0-9_]{0,63}$"
    },
    "text": {
      "description": "English source text; the app resolves it against its string catalogue like any other user-facing string.",
      "type": "string",
      "minLength": 1,
      "maxLength": 300,
      "pattern": "^[^\\u0000-\\u001f\\u007f]+$"
    },
    "relativePath": {
      "description": "Inside the extension directory. No component may be empty or start with '.'; the scanner realpaths it and refuses anything outside the extension root.",
      "type": "string",
      "maxLength": 1024,
      "pattern": "^[A-Za-z0-9_+@][A-Za-z0-9._+@ -]*(/[A-Za-z0-9_+@][A-Za-z0-9._+@ -]*)*$"
    },
    "templatePath": {
      "description": "A path inside a template directory. A component may contain {{placeholder}} tokens naming parameters whose type is path-safe (README ▸ Placeholders).",
      "type": "string",
      "maxLength": 1024,
      "pattern": "^([A-Za-z0-9_+@]|\\{\\{[a-z][A-Za-z0-9]*\\}\\})([A-Za-z0-9._+@ -]|\\{\\{[a-z][A-Za-z0-9]*\\}\\})*(/([A-Za-z0-9_+@]|\\{\\{[a-z][A-Za-z0-9]*\\}\\})([A-Za-z0-9._+@ -]|\\{\\{[a-z][A-Za-z0-9]*\\}\\})*)*$"
    },
    "archList": {
      "type": "array",
      "minItems": 1,
      "uniqueItems": true,
      "items": { "enum": ["arm64", "arm64e"] }
    },
    "relation": {
      "type": "string",
      "maxLength": 512,
      "pattern": "^[a-z0-9][a-z0-9+.-]+( \\((<<|<=|=|>=|>>) [0-9A-Za-z.+:~-]+\\))?( \\| [a-z0-9][a-z0-9+.-]+( \\((<<|<=|=|>=|>>) [0-9A-Za-z.+:~-]+\\))?)*$"
    },
    "perBootstrapRelations": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "rootless": { "type": "array", "uniqueItems": true, "items": { "$ref": "#/$defs/relation" } },
        "roothide": { "type": "array", "uniqueItems": true, "items": { "$ref": "#/$defs/relation" } }
      }
    },
    "scope": {
      "description": "template:<id>, support:<component>, or manifest.",
      "type": "string",
      "pattern": "^(template:[a-z][a-z0-9-]{0,63}|support:[a-z][a-z0-9-]{0,63}|manifest)$"
    },
    "supportComponent": {
      "type": "object",
      "additionalProperties": false,
      "required": ["summary", "architectures", "spdx", "license"],
      "properties": {
        "summary": { "$ref": "#/$defs/text" },
        "includeDirectories": {
          "type": "array",
          "maxItems": 8,
          "items": { "$ref": "#/$defs/relativePath" }
        },
        "linkStubDirectories": {
          "description": "Directories holding hand-written .tbd stubs, per bootstrap, added with -L/-F. A stub is a link input only: nothing in it is loaded or executed on the build device.",
          "type": "object",
          "additionalProperties": false,
          "minProperties": 1,
          "properties": {
            "rootless": { "$ref": "#/$defs/relativePath" },
            "roothide": { "$ref": "#/$defs/relativePath" }
          }
        },
        "libraries": {
          "type": "array",
          "uniqueItems": true,
          "items": { "type": "string", "pattern": "^[A-Za-z0-9_][A-Za-z0-9_+.-]{0,63}$" }
        },
        "frameworks": {
          "type": "array",
          "uniqueItems": true,
          "items": { "$ref": "#/$defs/identifier" }
        },
        "rpaths": {
          "description": "LC_RPATH entries per bootstrap. @PREFIX@ is replaced with '' (roothide) or '/var/jb' (rootless) by the build, like the packager does.",
          "type": "object",
          "additionalProperties": false,
          "properties": {
            "rootless": { "type": "array", "items": { "type": "string", "pattern": "^(@PREFIX@|@loader_path|@executable_path)?/[A-Za-z0-9._/+-]+$" } },
            "roothide": { "type": "array", "items": { "type": "string", "pattern": "^(@PREFIX@|@loader_path|@executable_path)?/[A-Za-z0-9._/+-]+$" } }
          }
        },
        "installNames": {
          "description": "The install name each stub carries, recorded so a reviewer and projectCheck can compare it with the stub file.",
          "$ref": "#/$defs/perBootstrapString"
        },
        "symbols": {
          "description": "The exported symbols the stubs declare and the templates may call: the declared compatible set.",
          "type": "array",
          "uniqueItems": true,
          "items": { "type": "string", "pattern": "^_[A-Za-z0-9_$.]+$" }
        },
        "architectures": { "$ref": "#/$defs/archList" },
        "runtimeDependencies": {
          "description": "The package providing these symbols at run time, per bootstrap.",
          "$ref": "#/$defs/perBootstrapRelations"
        },
        "spdx": { "enum": ["MIT", "BSD-2-Clause", "BSD-3-Clause", "Apache-2.0", "0BSD", "MIT-0"] },
        "license": { "$ref": "#/$defs/relativePath" }
      }
    },
    "perBootstrapString": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "rootless": { "type": "string", "maxLength": 512 },
        "roothide": { "type": "string", "maxLength": 512 }
      }
    },
    "parameter": {
      "type": "object",
      "additionalProperties": false,
      "required": ["name", "type", "label"],
      "properties": {
        "name": { "type": "string", "pattern": "^[a-z][A-Za-z0-9]{0,63}$" },
        "type": {
          "enum": [
            "projectName",
            "identifier",
            "bundleID",
            "packageID",
            "version",
            "deploymentTarget",
            "bundleIDList",
            "executableList",
            "string",
            "enum",
            "bool"
          ]
        },
        "label": { "$ref": "#/$defs/text" },
        "help": { "$ref": "#/$defs/text" },
        "required": {
          "description": "Informational: the create sheet marks the field. Every parameter needs a value or a default.",
          "type": "boolean"
        },
        "default": {},
        "values": {
          "description": "The allowed values of an enum parameter.",
          "type": "array",
          "minItems": 1,
          "uniqueItems": true,
          "items": { "type": "string", "pattern": "^[A-Za-z0-9_.+-]{1,64}$" }
        },
        "maxLength": { "type": "integer", "minimum": 1, "maximum": 200 }
      },
      "allOf": [
        {
          "if": { "properties": { "type": { "const": "enum" } } },
          "then": { "required": ["values"] },
          "else": { "not": { "required": ["values"] } }
        }
      ]
    },
    "templateFile": {
      "type": "object",
      "additionalProperties": false,
      "required": ["path", "format"],
      "properties": {
        "path": { "$ref": "#/$defs/templatePath" },
        "format": {
          "description": "Decides how every {{placeholder}} in the file is escaped and which parameter types may appear (README ▸ Placeholders). 'copy' substitutes nothing.",
          "enum": ["c", "objc", "swift", "plist-xml", "json", "deb-control", "shell", "text", "copy"]
        },
        "mode": { "enum": ["0644", "0755"] }
      }
    },
    "template": {
      "type": "object",
      "additionalProperties": false,
      "required": ["id", "directory", "displayName", "summary", "language", "project", "parameters", "files", "digest"],
      "properties": {
        "id": { "type": "string", "pattern": "^[a-z][a-z0-9-]{0,63}$" },
        "directory": {
          "description": "templates/<id>.",
          "type": "string",
          "pattern": "^templates/[a-z][a-z0-9-]{0,63}$"
        },
        "displayName": { "$ref": "#/$defs/text" },
        "summary": { "$ref": "#/$defs/text" },
        "language": { "enum": ["c", "objc", "swift"] },
        "toolchainComponents": {
          "type": "array",
          "uniqueItems": true,
          "items": { "enum": ["c-family", "swift"] }
        },
        "project": {
          "description": "The project description template inside the directory; after substitution it must validate as apelin-project.json.",
          "const": "apelin-project.json"
        },
        "parameters": {
          "type": "array",
          "maxItems": 32,
          "items": { "$ref": "#/$defs/parameter" }
        },
        "files": {
          "description": "Every file of the template, and nothing else: an undeclared file in the directory isolates the extension.",
          "type": "array",
          "minItems": 1,
          "maxItems": 256,
          "items": { "$ref": "#/$defs/templateFile" }
        },
        "digest": {
          "description": "README ▸ Template digest. Recorded as template.digest in every project made from it.",
          "$ref": "#/$defs/digest"
        }
      }
    },
    "provenanceEntry": {
      "type": "object",
      "additionalProperties": false,
      "required": ["scope", "origin", "adaptations"],
      "properties": {
        "scope": { "$ref": "#/$defs/scope" },
        "origin": {
          "enum": ["imported", "written"],
          "description": "imported: taken from a repository at a pinned commit. written: written for this extension, nothing copied."
        },
        "repository": {
          "type": "string",
          "pattern": "^(https://github\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+|local:[A-Za-z0-9_.-]+)$"
        },
        "commit": { "type": "string", "pattern": "^[0-9a-f]{40}$" },
        "paths": {
          "type": "array",
          "items": { "type": "string", "maxLength": 512 }
        },
        "adaptations": {
          "type": "array",
          "items": { "type": "string", "maxLength": 600 }
        }
      },
      "allOf": [
        {
          "if": { "properties": { "origin": { "const": "imported" } } },
          "then": { "required": ["repository", "commit", "paths"] }
        }
      ]
    }
  }
}
"""#
}
