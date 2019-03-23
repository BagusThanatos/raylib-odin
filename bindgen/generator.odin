/**
 * Odin binding generator from C header data.
 */

package bindgen

import "core:os"
import "core:strings"
import "core:fmt"
import "core:runtime"

GeneratorOptions :: struct {
    // Variable
    variableCase : Case,

    // Defines
    definePrefixes : []string,
    defineTransparentPrefixes : []string,
    definePostfixes : []string,
    defineTransparentPostfixes : []string,
    defineCase : Case,

    // Pseudo-types
    pseudoTypePrefixes : []string,
    pseudoTypeTransparentPrefixes : []string,
    pseudoTypePostfixes : []string,
    pseudoTypeTransparentPostfixes : []string,
    pseudoTypeCase : Case,

    // Functions
    functionPrefixes : []string,
    functionTransparentPrefixes : []string,
    functionPostfixes : []string,
    functionTransparentPostfixes : []string,
    functionCase : Case,

    // Enum values
    enumValuePrefixes : []string,
    enumValueTransparentPrefixes : []string,
    enumValuePostfixes : []string,
    enumValueTransparentPostfixes : []string,
    enumValueCase : Case,
    enumValueNameRemove : bool,
    enumValueNameRemovePostfixes : []string,

    parserOptions : ParserOptions,
}

GeneratorData :: struct {
    handle : os.Handle,
    nodes : Nodes,

    // References
    options : ^GeneratorOptions,
}

generate :: proc(
    packageName : string,
    foreignLibrary : string,
    outputFile : string,
    typesFile : string,
    bridgeFile : string,
    headerFiles : []string,
    options : GeneratorOptions,
) {
    data : GeneratorData;
    data.options = &options;

    // Parsing header files
    for headerFile in headerFiles {
        bytes, ok := os.read_entire_file(headerFile);
        if !ok {
            fmt.print_err("[bindgen] Unable to read file ", headerFile, "\n");
            return;
        }

        // We fuse the SOAs
        headerNodes := parse(bytes, options.parserOptions);
        merge_generic_nodes(&data.nodes.defines, &headerNodes.defines);
        merge_generic_nodes(&data.nodes.enumDefinitions, &headerNodes.enumDefinitions);
        merge_generic_nodes(&data.nodes.unionDefinitions, &headerNodes.unionDefinitions);
        merge_forward_declared_nodes(&data.nodes.structDefinitions, &headerNodes.structDefinitions);
        merge_generic_nodes(&data.nodes.functionDeclarations, &headerNodes.functionDeclarations);
        merge_generic_nodes(&data.nodes.typedefs, &headerNodes.typedefs);
    }

    // Outputing odin "types" file
    {
        errno : os.Errno;
        data.handle, errno = os.open(typesFile, os.O_WRONLY | os.O_CREATE | os.O_TRUNC);
        if errno != 0 {
            fmt.print_err("[bindgen] Unable to write to output file ", typesFile, " (", errno ,")\n");
            return;
        }
        defer os.close(data.handle);

        fmt.fprintln(data.handle, "//");
        fmt.fprintln(data.handle, "// generated by bindgen (https://github.com/Breush/odin-binding-generator)");
        fmt.fprintln(data.handle, "//");
        fmt.fprint(data.handle, "\n");

        fmt.fprint(data.handle, "package ", packageName, "_types\n");
        fmt.fprint(data.handle, "\n");
        fmt.fprint(data.handle, "import _c \"core:c\"\n");
        fmt.fprint(data.handle, "\n");


        // Exporting
        export_defines(&data);
        export_typedefs(&data);
        export_enums(&data);
        export_structs(&data);
        export_unions(&data);

        fmt.fprint(data.handle, packageName, "_Funcs :: struct {\n");
        export_functions(&data, Export_Functions_Mode.Pointer_In_Struct);
        fmt.fprint(data.handle, "}\n\n");

    }

    // Outputing odin "bindings" file
    {
        errno : os.Errno;
        data.handle, errno = os.open(outputFile, os.O_WRONLY | os.O_CREATE | os.O_TRUNC);
        if errno != 0 {
            fmt.print_err("[bindgen] Unable to write to output file ", outputFile, " (", errno ,")\n");
            return;
        }
        defer os.close(data.handle);

        fmt.fprintf(data.handle, `
//
// THIS FILE WAS AUTOGENERATED
//

package %s

foreign import "%s"

import _c "core:c"

using import "../%s_types"

get_function_pointers :: proc(funcs: ^%s_Funcs) {
`, packageName, foreignLibrary, packageName, packageName);

        // assign incoming func pointers to struct
        for node in data.nodes.functionDeclarations {
            function_name := clean_function_name(node.name, data.options);
            fmt.fprintf(data.handle, "    funcs.%s = %s;\n", function_name, function_name);
        }

        fmt.fprint(data.handle, "}\n\n");

        // Foreign block for functions
        foreignLibrarySimple := simplify_library_name(foreignLibrary);
        fmt.fprint(data.handle, "@(default_calling_convention=\"c\")\n");
        fmt.fprint(data.handle, "foreign ", foreignLibrarySimple, " {\n");
        fmt.fprint(data.handle, "\n");

        export_functions(&data);

        fmt.fprint(data.handle, "}\n");
    }

    // bridge "plugin" file
    {
        errno : os.Errno;
        data.handle, errno = os.open(bridgeFile, os.O_WRONLY | os.O_CREATE | os.O_TRUNC);
        if errno != 0 {
            fmt.print_err("[bindgen] Unable to write to output file ", bridgeFile, " (", errno ,")\n");
            return;
        }
        defer os.close(data.handle);

        fmt.fprintf(data.handle, `
package %s

using import "../%s_types"

import _c "core:c"

bridge_init :: proc(funcs: ^%s_Funcs) {
`, packageName, packageName, packageName);

        count := 0;

        // assign incoming struct function pointers to package level function pointers 
        for node in data.nodes.functionDeclarations {
            function_name := clean_function_name(node.name, data.options);
            if count == 0 {
                fmt.fprint(data.handle, "    assert(funcs != nil);\n");
                fmt.fprintf(data.handle, "    assert(funcs.%s != nil);\n\n", function_name);
            }
            fmt.fprintf(data.handle, "    %s = funcs.%s;\n", function_name, function_name);
            count += 1;
        }

        fmt.fprintf(data.handle, `}

bridge_deinit :: proc() {
}

`);

        export_functions(&data, Export_Functions_Mode.Plugin_Pointers);
    }
}

// system:foo.lib -> foo
simplify_library_name :: proc(libraryName : string) -> string {
    startOffset := 0;
    endOffset := len(libraryName);

    for c, i in libraryName {
        if startOffset == 0 && c == ':' {
            startOffset = i + 1;
        }
        else if c == '.' {
            endOffset = i;
            break;
        }
    }

    return libraryName[startOffset:endOffset];
}

merge_generic_nodes :: proc(nodes : ^$T, headerNodes : ^T) {
    for headerNode in headerNodes {
        // Check that there are no duplicated nodes (due to forward declaration or such)
        duplicatedIndex := -1;
        for i := 0; i < len(nodes); i += 1 {
            node := nodes[i];
            if node.name == headerNode.name {
                duplicatedIndex = i;
                break;
            }
        }

        if duplicatedIndex < 0 {
            append(nodes, headerNode);
        }
    }
}

merge_forward_declared_nodes :: proc(nodes : ^$T, headerNodes : ^T) {
    for headerNode in headerNodes {
        // Check that there are no duplicated nodes (due to forward declaration or such)
        duplicatedIndex := -1;
        for i := 0; i < len(nodes); i += 1 {
            node := nodes[i];
            if node.name == headerNode.name {
                duplicatedIndex = i;
                break;
            }
        }

        if duplicatedIndex < 0 {
            append(nodes, headerNode);
        }
        else if !headerNode.forwardDeclared {
            nodes[duplicatedIndex] = headerNode;
        }
    }
}