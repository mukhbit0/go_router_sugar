import 'dart:io';
import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:path/path.dart' as p;
import '../route_info.dart';

class RouteAnalyzer {
  Future<List<RouteInfo>> analyze(String pagesDirectory) async {
    final routes = <RouteInfo>[];
    final packageName = await _getPackageName();

    // Add safety check for directory existence
    final dir = Directory(pagesDirectory);
    if (!dir.existsSync()) {
      print('⚠️ Warning: Pages directory "$pagesDirectory" does not exist.');
      return routes;
    }

    try {
      final allFiles = <File>[];

      // Collect all files first with error handling
      try {
        await for (final entity in dir.list(recursive: true)) {
          if (entity is File && entity.path.endsWith('_page.dart')) {
            allFiles.add(entity);
          }
        }
      } on Exception catch (e) {
        print('⚠️ Warning: Error listing directory contents: $e');
        return routes;
      }

      if (allFiles.isEmpty) {
        print('ℹ️ No *_page.dart files found in $pagesDirectory');
        return routes;
      }

      print('🔍 Found ${allFiles.length} page file(s) to analyze...');

      // Process each file with comprehensive error handling
      for (final entity in allFiles) {
        try {
          final content = await entity.readAsString();

          if (content.trim().isEmpty) {
            print('⚠️ Warning: Empty file skipped: ${entity.path}');
            continue;
          }

          CompilationUnit? unit;
          try {
            final parseResult = parseString(
              content: content,
              featureSet: FeatureSet.latestLanguageVersion(),
              throwIfDiagnostics: false,
            );
            unit = parseResult.unit;

            if (parseResult.errors.isNotEmpty) {
              print(
                  '⚠️ Warning: Parse errors in ${entity.path}: ${parseResult.errors.length} error(s)');
              // Continue anyway as some errors might not prevent analysis
            }
          } on Exception catch (parseError) {
            print('⚠️ Warning: Parse error in ${entity.path}: $parseError');
            continue;
          }

          final visitor = _WidgetVisitor();
          try {
            unit.visitChildren(visitor);
          } on Exception catch (visitorError) {
            print('⚠️ Warning: Visitor error in ${entity.path}: $visitorError');
            continue;
          }

          if (visitor.className != null) {
            try {
              final relativePath =
                  p.relative(entity.path, from: pagesDirectory);
              final routePath = _filePathToRoutePath(relativePath);
              final pathFromLib = p.relative(entity.path, from: 'lib');
              final importPath =
                  'package:$packageName/${pathFromLib.replaceAll('\\', '/')}';

              // Convert constructor params to RouteParameter list
              final parameters = visitor.constructorParams.entries
                  .map((entry) => RouteParameter(name: entry.key))
                  .toList();

              routes.add(RouteInfo(
                filePath: entity.path,
                routePath: routePath,
                className: visitor.className!,
                parameters: parameters,
                importPath: importPath,
              ));
              print('✅ Analyzed: ${visitor.className} -> $routePath');
            } on Exception catch (routeCreationError) {
              print(
                  '⚠️ Warning: Error creating route info for ${entity.path}: $routeCreationError');
              continue;
            }
          } else {
            print('⚠️ Warning: No valid Widget class found in ${entity.path}');
          }
        } on Exception catch (e, stackTrace) {
          print('⚠️ Warning: Failed to process ${entity.path}: $e');
          // Print abbreviated stack trace for debugging
          final stackLines =
              stackTrace.toString().split('\n').take(3).join('\n');
          print('   Stack trace preview: $stackLines');
          // Continue processing other files
          continue;
        }
      }
    } on Exception catch (e, stackTrace) {
      print('❌ Critical error scanning directory "$pagesDirectory": $e');
      print('Stack trace: $stackTrace');
      return routes; // Return partial results instead of failing completely
    }

    try {
      routes.sort((a, b) => a.routePath.compareTo(b.routePath));
    } on Exception catch (sortError) {
      print('⚠️ Warning: Error sorting routes: $sortError');
      // Routes will be returned unsorted but functional
    }

    print('📋 Total routes found: ${routes.length}');
    return routes;
  }

  Future<String> _getPackageName() async {
    final pubspecFile = File('pubspec.yaml');
    if (!await pubspecFile.exists()) {
      print(
          '⚠️ Warning: pubspec.yaml not found. Run the generator from your project root.');
      return 'your_app_name'; // Fallback
    }
    try {
      final lines = await pubspecFile.readAsLines();
      for (final line in lines) {
        if (line.startsWith('name:')) {
          return line.substring(5).trim();
        }
      }
    } catch (e) {
      print('⚠️ Warning: Could not read or parse pubspec.yaml: $e');
    }
    print('⚠️ Warning: Could not find "name" in pubspec.yaml.');
    return 'your_app_name'; // Fallback
  }

  String _filePathToRoutePath(String filePath) {
    // Normalize path separators and remove extension
    final pathWithoutExt =
        filePath.replaceAll('\\', '/').replaceAll('_page.dart', '');

    // Split into segments and process each one
    final segments =
        pathWithoutExt.split('/').where((s) => s.isNotEmpty).map((s) {
      // Convert [param] to :param for dynamic routes
      if (s.startsWith('[') && s.endsWith(']')) {
        return ':${s.substring(1, s.length - 1)}';
      }
      return s;
    }).toList();

    // Handle special cases
    if (segments.isEmpty) {
      return '/';
    }

    // Build the route path
    final result = '/${segments.join('/')}';

    // Remove trailing /index if present
    final finalPath = result.endsWith('/index')
        ? result.substring(0, result.length - 6)
        : result;

    // Ensure we always return a valid path starting with /
    if (finalPath.isEmpty || finalPath == '/') {
      return '/';
    }

    // Ensure path starts with /
    return finalPath.startsWith('/') ? finalPath : '/$finalPath';
  }
}

class _WidgetVisitor extends GeneralizingAstVisitor<void> {
  String? className;
  Map<String, String> constructorParams = {};

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    if (className == null && _isWidgetClass(node)) {
      className = node.name.lexeme;

      // Look for constructors
      for (final member in node.members) {
        if (member is ConstructorDeclaration) {
          // Process both named and unnamed constructors
          _processConstructor(member);
          break; // Use the first constructor found
        }
      }
    }
  }

  bool _isWidgetClass(ClassDeclaration node) {
    final extendsClause = node.extendsClause;
    if (extendsClause != null) {
      final superclass = extendsClause.superclass.toSource();
      return superclass.contains('StatelessWidget') ||
          superclass.contains('StatefulWidget') ||
          superclass.contains('Widget');
    }
    return false;
  }

  void _processConstructor(ConstructorDeclaration constructor) {
    try {
      for (final param in constructor.parameters.parameters) {
        try {
          String? paramName;
          String? paramType;

          // Safely extract parameter name and type using toString() as fallback
          if (param is DefaultFormalParameter) {
            final normalParam = param.parameter;
            if (normalParam is FieldFormalParameter) {
              try {
                // Try to get the name safely
                final nameToken = normalParam.name;
                paramName = nameToken.lexeme;
                paramType = normalParam.type?.toSource();
              } on Exception {
                // Fallback: parse from string representation
                final paramStr = normalParam.toString();
                final parts = paramStr.split(' ');
                paramName = parts.isNotEmpty
                    ? parts.last.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '')
                    : null;
              }
            } else if (normalParam is SimpleFormalParameter) {
              try {
                final nameToken = normalParam.name;
                paramName = nameToken!.lexeme;
                paramType = normalParam.type?.toSource();
              } on Exception {
                final paramStr = normalParam.toString();
                final parts = paramStr.split(' ');
                paramName = parts.isNotEmpty
                    ? parts.last.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '')
                    : null;
              }
            }
          } else if (param is FieldFormalParameter) {
            try {
              final nameToken = param.name;
              paramName = nameToken.lexeme;
              paramType = param.type?.toSource();
            } on Exception {
              final paramStr = param.toString();
              final parts = paramStr.split(' ');
              paramName = parts.isNotEmpty
                  ? parts.last.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '')
                  : null;
            }
          } else if (param is SimpleFormalParameter) {
            try {
              final nameToken = param.name;
              paramName = nameToken!.lexeme;
              paramType = param.type?.toSource();
            } on Exception {
              final paramStr = param.toString();
              final parts = paramStr.split(' ');
              paramName = parts.isNotEmpty
                  ? parts.last.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '')
                  : null;
            }
          }

          // Clean up parameter info
          if (paramName != null && paramName != 'key' && paramName.isNotEmpty) {
            final cleanType =
                (paramType ?? 'dynamic').replaceAll('?', '').trim();
            if (cleanType.isNotEmpty) {
              constructorParams[paramName] = cleanType;
            }
          }
        } on Exception {
          // Try fallback method for parameter extraction
          try {
            // Using deprecated member with an ignore for wider compatibility.
            // ignore: deprecated_member_use
            final element = param.declaredElement;
            if (element != null &&
                element.name != 'key' &&
                element.name.isNotEmpty) {
              // Using getDisplayString() without deprecated parameters
              final displayString = element.type.getDisplayString();
              constructorParams[element.name] =
                  displayString.replaceAll('?', '').trim();
            }
          } on Exception {
            print(
                '⚠️ Warning: Failed to extract parameter info (tried both methods): param type = ${param.runtimeType}');
            // Skip this parameter rather than failing the entire analysis
            continue;
          }
        }
      }
    } on Exception catch (e) {
      print('⚠️ Warning: Error processing constructor parameters: $e');
      // Don't let constructor parsing errors break the entire analysis
    }
  }
}
