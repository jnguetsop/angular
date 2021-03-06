library angular2.transform.directive_processor.rewriter;

import 'package:analyzer/analyzer.dart';
import 'package:analyzer/src/generated/java_core.dart';
import 'package:angular2/src/transform/common/annotation_matcher.dart';
import 'package:angular2/src/transform/common/logging.dart';
import 'package:angular2/src/transform/common/names.dart';
import 'package:barback/barback.dart' show AssetId;
import 'package:path/path.dart' as path;

import 'visitors.dart';

/// Generates a file registering all Angular 2 `Directive`s found in `code` in
/// ngDeps format [TODO(kegluneq): documentation reference needed]. `assetId` is
/// the id of the asset containing `code`.
///
/// If no Angular 2 `Directive`s are found in `code`, returns the empty
/// string unless `forceGenerate` is true, in which case an empty ngDeps
/// file is created.
String createNgDeps(
    String code, AssetId assetId, AnnotationMatcher annotationMatcher) {
  // TODO(kegluneq): Shortcut if we can determine that there are no
  // [Directive]s present, taking into account `export`s.
  var writer = new PrintStringWriter();
  var visitor = new CreateNgDepsVisitor(writer, assetId, annotationMatcher);
  parseCompilationUnit(code, name: assetId.toString()).accept(visitor);
  return '$writer';
}

/// Visitor responsible for processing [CompilationUnit] and creating an
/// associated .ng_deps.dart file.
class CreateNgDepsVisitor extends Object with SimpleAstVisitor<Object> {
  final PrintWriter writer;
  bool _foundNgDirectives = false;
  bool _wroteImport = false;
  final ToSourceVisitor _copyVisitor;
  final FactoryTransformVisitor _factoryVisitor;
  final ParameterTransformVisitor _paramsVisitor;
  final AnnotationsTransformVisitor _metaVisitor;
  final AnnotationMatcher _annotationMatcher;

  /// The assetId for the file which we are parsing.
  final AssetId assetId;

  CreateNgDepsVisitor(PrintWriter writer, this.assetId, this._annotationMatcher)
      : writer = writer,
        _copyVisitor = new ToSourceVisitor(writer),
        _factoryVisitor = new FactoryTransformVisitor(writer),
        _paramsVisitor = new ParameterTransformVisitor(writer),
        _metaVisitor = new AnnotationsTransformVisitor(writer);

  void _visitNodeListWithSeparator(NodeList<AstNode> list, String separator) {
    if (list == null) return;
    for (var i = 0, iLen = list.length; i < iLen; ++i) {
      if (i != 0) {
        writer.print(separator);
      }
      list[i].accept(this);
    }
  }

  @override
  Object visitCompilationUnit(CompilationUnit node) {
    _visitNodeListWithSeparator(node.directives, " ");
    _openFunctionWrapper();
    _visitNodeListWithSeparator(node.declarations, " ");
    _closeFunctionWrapper();
    return null;
  }

  /// Write the import to the file the .ng_deps.dart file is based on if it
  /// has not yet been written.
  void _maybeWriteImport() {
    if (_wroteImport) return;
    _wroteImport = true;
    writer.print('''import '${path.basename(assetId.path)}';''');
  }

  @override
  Object visitImportDirective(ImportDirective node) {
    _maybeWriteImport();
    return node.accept(_copyVisitor);
  }

  @override
  Object visitExportDirective(ExportDirective node) {
    _maybeWriteImport();
    return node.accept(_copyVisitor);
  }

  void _openFunctionWrapper() {
    _maybeWriteImport();
    writer.print('var _visited = false;'
        'void ${SETUP_METHOD_NAME}(${REFLECTOR_VAR_NAME}) {'
        'if (_visited) return; _visited = true;');
  }

  void _closeFunctionWrapper() {
    if (_foundNgDirectives) {
      writer.print(';');
    }
    writer.print('}');
  }

  ConstructorDeclaration _getCtor(ClassDeclaration node) {
    int numCtorsFound = 0;
    var ctor = null;

    for (ClassMember classMember in node.members) {
      if (classMember is ConstructorDeclaration) {
        numCtorsFound++;
        ConstructorDeclaration constructor = classMember;

        // Use the unnnamed constructor if it is present.
        // Otherwise, use the first encountered.
        if (ctor == null) {
          ctor = constructor;
        } else if (constructor.name == null) {
          ctor = constructor;
        }
      }
    }
    if (numCtorsFound > 1) {
      var ctorName = ctor.name;
      ctorName = ctorName == null
          ? 'the unnamed constructor'
          : 'constructor "${ctorName}"';
      logger.warning('Found ${numCtorsFound} ctors for class ${node.name},'
          'Using ${ctorName}.');
    }
    return ctor;
  }

  void _generateEmptyFactory(String typeName) {
    writer.print('() => new ${typeName}()');
  }

  void _generateEmptyParams() => writer.print('const []');

  @override
  Object visitClassDeclaration(ClassDeclaration node) {
    if (!node.metadata.any((a) => _annotationMatcher.hasMatch(a, assetId))) {
      return null;
    }

    var ctor = _getCtor(node);

    if (!_foundNgDirectives) {
      // The receiver for cascaded calls.
      writer.print(REFLECTOR_VAR_NAME);
      _foundNgDirectives = true;
    }
    writer.print('..registerType(');
    node.name.accept(this);
    writer.print(''', {'factory': ''');
    if (ctor == null) {
      _generateEmptyFactory(node.name.toString());
    } else {
      ctor.accept(_factoryVisitor);
    }
    writer.print(''', 'parameters': ''');
    if (ctor == null) {
      _generateEmptyParams();
    } else {
      ctor.accept(_paramsVisitor);
    }
    writer.print(''', 'annotations': ''');
    node.accept(_metaVisitor);
    writer.print('})');
    return null;
  }

  Object _nodeToSource(AstNode node) {
    if (node == null) return null;
    return node.accept(_copyVisitor);
  }

  @override
  Object visitLibraryDirective(LibraryDirective node) {
    if (node != null && node.name != null) {
      writer.print('library ');
      _nodeToSource(node.name);
      writer.print('$DEPS_EXTENSION;');
    }
    return null;
  }

  @override
  Object visitPartOfDirective(PartOfDirective node) {
    // TODO(kegluneq): Consider importing [node.libraryName].
    logger.warning('[${assetId}]: '
        'Found `part of` directive while generating ${DEPS_EXTENSION} file, '
        'Transform may fail due to missing imports in generated file.');
    return null;
  }

  @override
  Object visitPrefixedIdentifier(PrefixedIdentifier node) =>
      _nodeToSource(node);

  @override
  Object visitSimpleIdentifier(SimpleIdentifier node) => _nodeToSource(node);
}
