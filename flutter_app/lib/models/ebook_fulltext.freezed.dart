// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'ebook_fulltext.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
  'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models',
);

/// @nodoc
mixin _$SentenceSpan {
  String get id => throw _privateConstructorUsedError;
  String get text => throw _privateConstructorUsedError;
  int get startChar => throw _privateConstructorUsedError;
  int get endChar => throw _privateConstructorUsedError;

  /// Create a copy of SentenceSpan
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $SentenceSpanCopyWith<SentenceSpan> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $SentenceSpanCopyWith<$Res> {
  factory $SentenceSpanCopyWith(
    SentenceSpan value,
    $Res Function(SentenceSpan) then,
  ) = _$SentenceSpanCopyWithImpl<$Res, SentenceSpan>;
  @useResult
  $Res call({String id, String text, int startChar, int endChar});
}

/// @nodoc
class _$SentenceSpanCopyWithImpl<$Res, $Val extends SentenceSpan>
    implements $SentenceSpanCopyWith<$Res> {
  _$SentenceSpanCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of SentenceSpan
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? id = null,
    Object? text = null,
    Object? startChar = null,
    Object? endChar = null,
  }) {
    return _then(
      _value.copyWith(
            id: null == id
                ? _value.id
                : id // ignore: cast_nullable_to_non_nullable
                      as String,
            text: null == text
                ? _value.text
                : text // ignore: cast_nullable_to_non_nullable
                      as String,
            startChar: null == startChar
                ? _value.startChar
                : startChar // ignore: cast_nullable_to_non_nullable
                      as int,
            endChar: null == endChar
                ? _value.endChar
                : endChar // ignore: cast_nullable_to_non_nullable
                      as int,
          )
          as $Val,
    );
  }
}

/// @nodoc
abstract class _$$SentenceSpanImplCopyWith<$Res>
    implements $SentenceSpanCopyWith<$Res> {
  factory _$$SentenceSpanImplCopyWith(
    _$SentenceSpanImpl value,
    $Res Function(_$SentenceSpanImpl) then,
  ) = __$$SentenceSpanImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({String id, String text, int startChar, int endChar});
}

/// @nodoc
class __$$SentenceSpanImplCopyWithImpl<$Res>
    extends _$SentenceSpanCopyWithImpl<$Res, _$SentenceSpanImpl>
    implements _$$SentenceSpanImplCopyWith<$Res> {
  __$$SentenceSpanImplCopyWithImpl(
    _$SentenceSpanImpl _value,
    $Res Function(_$SentenceSpanImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of SentenceSpan
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? id = null,
    Object? text = null,
    Object? startChar = null,
    Object? endChar = null,
  }) {
    return _then(
      _$SentenceSpanImpl(
        id: null == id
            ? _value.id
            : id // ignore: cast_nullable_to_non_nullable
                  as String,
        text: null == text
            ? _value.text
            : text // ignore: cast_nullable_to_non_nullable
                  as String,
        startChar: null == startChar
            ? _value.startChar
            : startChar // ignore: cast_nullable_to_non_nullable
                  as int,
        endChar: null == endChar
            ? _value.endChar
            : endChar // ignore: cast_nullable_to_non_nullable
                  as int,
      ),
    );
  }
}

/// @nodoc

class _$SentenceSpanImpl implements _SentenceSpan {
  const _$SentenceSpanImpl({
    required this.id,
    required this.text,
    required this.startChar,
    required this.endChar,
  });

  @override
  final String id;
  @override
  final String text;
  @override
  final int startChar;
  @override
  final int endChar;

  @override
  String toString() {
    return 'SentenceSpan(id: $id, text: $text, startChar: $startChar, endChar: $endChar)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$SentenceSpanImpl &&
            (identical(other.id, id) || other.id == id) &&
            (identical(other.text, text) || other.text == text) &&
            (identical(other.startChar, startChar) ||
                other.startChar == startChar) &&
            (identical(other.endChar, endChar) || other.endChar == endChar));
  }

  @override
  int get hashCode => Object.hash(runtimeType, id, text, startChar, endChar);

  /// Create a copy of SentenceSpan
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$SentenceSpanImplCopyWith<_$SentenceSpanImpl> get copyWith =>
      __$$SentenceSpanImplCopyWithImpl<_$SentenceSpanImpl>(this, _$identity);
}

abstract class _SentenceSpan implements SentenceSpan {
  const factory _SentenceSpan({
    required final String id,
    required final String text,
    required final int startChar,
    required final int endChar,
  }) = _$SentenceSpanImpl;

  @override
  String get id;
  @override
  String get text;
  @override
  int get startChar;
  @override
  int get endChar;

  /// Create a copy of SentenceSpan
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$SentenceSpanImplCopyWith<_$SentenceSpanImpl> get copyWith =>
      throw _privateConstructorUsedError;
}

FulltextSegment _$FulltextSegmentFromJson(Map<String, dynamic> json) {
  return _FulltextSegment.fromJson(json);
}

/// @nodoc
mixin _$FulltextSegment {
  String? get id => throw _privateConstructorUsedError;
  String get text => throw _privateConstructorUsedError;
  int? get startMs => throw _privateConstructorUsedError;
  int? get endMs => throw _privateConstructorUsedError;

  /// Serializes this FulltextSegment to a JSON map.
  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;

  /// Create a copy of FulltextSegment
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $FulltextSegmentCopyWith<FulltextSegment> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $FulltextSegmentCopyWith<$Res> {
  factory $FulltextSegmentCopyWith(
    FulltextSegment value,
    $Res Function(FulltextSegment) then,
  ) = _$FulltextSegmentCopyWithImpl<$Res, FulltextSegment>;
  @useResult
  $Res call({String? id, String text, int? startMs, int? endMs});
}

/// @nodoc
class _$FulltextSegmentCopyWithImpl<$Res, $Val extends FulltextSegment>
    implements $FulltextSegmentCopyWith<$Res> {
  _$FulltextSegmentCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of FulltextSegment
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? id = freezed,
    Object? text = null,
    Object? startMs = freezed,
    Object? endMs = freezed,
  }) {
    return _then(
      _value.copyWith(
            id: freezed == id
                ? _value.id
                : id // ignore: cast_nullable_to_non_nullable
                      as String?,
            text: null == text
                ? _value.text
                : text // ignore: cast_nullable_to_non_nullable
                      as String,
            startMs: freezed == startMs
                ? _value.startMs
                : startMs // ignore: cast_nullable_to_non_nullable
                      as int?,
            endMs: freezed == endMs
                ? _value.endMs
                : endMs // ignore: cast_nullable_to_non_nullable
                      as int?,
          )
          as $Val,
    );
  }
}

/// @nodoc
abstract class _$$FulltextSegmentImplCopyWith<$Res>
    implements $FulltextSegmentCopyWith<$Res> {
  factory _$$FulltextSegmentImplCopyWith(
    _$FulltextSegmentImpl value,
    $Res Function(_$FulltextSegmentImpl) then,
  ) = __$$FulltextSegmentImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({String? id, String text, int? startMs, int? endMs});
}

/// @nodoc
class __$$FulltextSegmentImplCopyWithImpl<$Res>
    extends _$FulltextSegmentCopyWithImpl<$Res, _$FulltextSegmentImpl>
    implements _$$FulltextSegmentImplCopyWith<$Res> {
  __$$FulltextSegmentImplCopyWithImpl(
    _$FulltextSegmentImpl _value,
    $Res Function(_$FulltextSegmentImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of FulltextSegment
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? id = freezed,
    Object? text = null,
    Object? startMs = freezed,
    Object? endMs = freezed,
  }) {
    return _then(
      _$FulltextSegmentImpl(
        id: freezed == id
            ? _value.id
            : id // ignore: cast_nullable_to_non_nullable
                  as String?,
        text: null == text
            ? _value.text
            : text // ignore: cast_nullable_to_non_nullable
                  as String,
        startMs: freezed == startMs
            ? _value.startMs
            : startMs // ignore: cast_nullable_to_non_nullable
                  as int?,
        endMs: freezed == endMs
            ? _value.endMs
            : endMs // ignore: cast_nullable_to_non_nullable
                  as int?,
      ),
    );
  }
}

/// @nodoc
@JsonSerializable()
class _$FulltextSegmentImpl implements _FulltextSegment {
  const _$FulltextSegmentImpl({
    this.id,
    required this.text,
    this.startMs,
    this.endMs,
  });

  factory _$FulltextSegmentImpl.fromJson(Map<String, dynamic> json) =>
      _$$FulltextSegmentImplFromJson(json);

  @override
  final String? id;
  @override
  final String text;
  @override
  final int? startMs;
  @override
  final int? endMs;

  @override
  String toString() {
    return 'FulltextSegment(id: $id, text: $text, startMs: $startMs, endMs: $endMs)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$FulltextSegmentImpl &&
            (identical(other.id, id) || other.id == id) &&
            (identical(other.text, text) || other.text == text) &&
            (identical(other.startMs, startMs) || other.startMs == startMs) &&
            (identical(other.endMs, endMs) || other.endMs == endMs));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, id, text, startMs, endMs);

  /// Create a copy of FulltextSegment
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$FulltextSegmentImplCopyWith<_$FulltextSegmentImpl> get copyWith =>
      __$$FulltextSegmentImplCopyWithImpl<_$FulltextSegmentImpl>(
        this,
        _$identity,
      );

  @override
  Map<String, dynamic> toJson() {
    return _$$FulltextSegmentImplToJson(this);
  }
}

abstract class _FulltextSegment implements FulltextSegment {
  const factory _FulltextSegment({
    final String? id,
    required final String text,
    final int? startMs,
    final int? endMs,
  }) = _$FulltextSegmentImpl;

  factory _FulltextSegment.fromJson(Map<String, dynamic> json) =
      _$FulltextSegmentImpl.fromJson;

  @override
  String? get id;
  @override
  String get text;
  @override
  int? get startMs;
  @override
  int? get endMs;

  /// Create a copy of FulltextSegment
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$FulltextSegmentImplCopyWith<_$FulltextSegmentImpl> get copyWith =>
      throw _privateConstructorUsedError;
}

FulltextChapter _$FulltextChapterFromJson(Map<String, dynamic> json) {
  return _FulltextChapter.fromJson(json);
}

/// @nodoc
mixin _$FulltextChapter {
  @JsonKey(fromJson: _flexInt)
  int get index => throw _privateConstructorUsedError;
  String? get name => throw _privateConstructorUsedError;
  String get text => throw _privateConstructorUsedError;
  String? get html => throw _privateConstructorUsedError;
  String? get css => throw _privateConstructorUsedError;
  int? get charCount => throw _privateConstructorUsedError;
  List<FulltextSegment>? get segments => throw _privateConstructorUsedError;

  /// Serializes this FulltextChapter to a JSON map.
  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;

  /// Create a copy of FulltextChapter
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $FulltextChapterCopyWith<FulltextChapter> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $FulltextChapterCopyWith<$Res> {
  factory $FulltextChapterCopyWith(
    FulltextChapter value,
    $Res Function(FulltextChapter) then,
  ) = _$FulltextChapterCopyWithImpl<$Res, FulltextChapter>;
  @useResult
  $Res call({
    @JsonKey(fromJson: _flexInt) int index,
    String? name,
    String text,
    String? html,
    String? css,
    int? charCount,
    List<FulltextSegment>? segments,
  });
}

/// @nodoc
class _$FulltextChapterCopyWithImpl<$Res, $Val extends FulltextChapter>
    implements $FulltextChapterCopyWith<$Res> {
  _$FulltextChapterCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of FulltextChapter
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? index = null,
    Object? name = freezed,
    Object? text = null,
    Object? html = freezed,
    Object? css = freezed,
    Object? charCount = freezed,
    Object? segments = freezed,
  }) {
    return _then(
      _value.copyWith(
            index: null == index
                ? _value.index
                : index // ignore: cast_nullable_to_non_nullable
                      as int,
            name: freezed == name
                ? _value.name
                : name // ignore: cast_nullable_to_non_nullable
                      as String?,
            text: null == text
                ? _value.text
                : text // ignore: cast_nullable_to_non_nullable
                      as String,
            html: freezed == html
                ? _value.html
                : html // ignore: cast_nullable_to_non_nullable
                      as String?,
            css: freezed == css
                ? _value.css
                : css // ignore: cast_nullable_to_non_nullable
                      as String?,
            charCount: freezed == charCount
                ? _value.charCount
                : charCount // ignore: cast_nullable_to_non_nullable
                      as int?,
            segments: freezed == segments
                ? _value.segments
                : segments // ignore: cast_nullable_to_non_nullable
                      as List<FulltextSegment>?,
          )
          as $Val,
    );
  }
}

/// @nodoc
abstract class _$$FulltextChapterImplCopyWith<$Res>
    implements $FulltextChapterCopyWith<$Res> {
  factory _$$FulltextChapterImplCopyWith(
    _$FulltextChapterImpl value,
    $Res Function(_$FulltextChapterImpl) then,
  ) = __$$FulltextChapterImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({
    @JsonKey(fromJson: _flexInt) int index,
    String? name,
    String text,
    String? html,
    String? css,
    int? charCount,
    List<FulltextSegment>? segments,
  });
}

/// @nodoc
class __$$FulltextChapterImplCopyWithImpl<$Res>
    extends _$FulltextChapterCopyWithImpl<$Res, _$FulltextChapterImpl>
    implements _$$FulltextChapterImplCopyWith<$Res> {
  __$$FulltextChapterImplCopyWithImpl(
    _$FulltextChapterImpl _value,
    $Res Function(_$FulltextChapterImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of FulltextChapter
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? index = null,
    Object? name = freezed,
    Object? text = null,
    Object? html = freezed,
    Object? css = freezed,
    Object? charCount = freezed,
    Object? segments = freezed,
  }) {
    return _then(
      _$FulltextChapterImpl(
        index: null == index
            ? _value.index
            : index // ignore: cast_nullable_to_non_nullable
                  as int,
        name: freezed == name
            ? _value.name
            : name // ignore: cast_nullable_to_non_nullable
                  as String?,
        text: null == text
            ? _value.text
            : text // ignore: cast_nullable_to_non_nullable
                  as String,
        html: freezed == html
            ? _value.html
            : html // ignore: cast_nullable_to_non_nullable
                  as String?,
        css: freezed == css
            ? _value.css
            : css // ignore: cast_nullable_to_non_nullable
                  as String?,
        charCount: freezed == charCount
            ? _value.charCount
            : charCount // ignore: cast_nullable_to_non_nullable
                  as int?,
        segments: freezed == segments
            ? _value._segments
            : segments // ignore: cast_nullable_to_non_nullable
                  as List<FulltextSegment>?,
      ),
    );
  }
}

/// @nodoc
@JsonSerializable()
class _$FulltextChapterImpl extends _FulltextChapter {
  const _$FulltextChapterImpl({
    @JsonKey(fromJson: _flexInt) required this.index,
    this.name,
    required this.text,
    this.html,
    this.css,
    this.charCount,
    final List<FulltextSegment>? segments,
  }) : _segments = segments,
       super._();

  factory _$FulltextChapterImpl.fromJson(Map<String, dynamic> json) =>
      _$$FulltextChapterImplFromJson(json);

  @override
  @JsonKey(fromJson: _flexInt)
  final int index;
  @override
  final String? name;
  @override
  final String text;
  @override
  final String? html;
  @override
  final String? css;
  @override
  final int? charCount;
  final List<FulltextSegment>? _segments;
  @override
  List<FulltextSegment>? get segments {
    final value = _segments;
    if (value == null) return null;
    if (_segments is EqualUnmodifiableListView) return _segments;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(value);
  }

  @override
  String toString() {
    return 'FulltextChapter(index: $index, name: $name, text: $text, html: $html, css: $css, charCount: $charCount, segments: $segments)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$FulltextChapterImpl &&
            (identical(other.index, index) || other.index == index) &&
            (identical(other.name, name) || other.name == name) &&
            (identical(other.text, text) || other.text == text) &&
            (identical(other.html, html) || other.html == html) &&
            (identical(other.css, css) || other.css == css) &&
            (identical(other.charCount, charCount) ||
                other.charCount == charCount) &&
            const DeepCollectionEquality().equals(other._segments, _segments));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
    runtimeType,
    index,
    name,
    text,
    html,
    css,
    charCount,
    const DeepCollectionEquality().hash(_segments),
  );

  /// Create a copy of FulltextChapter
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$FulltextChapterImplCopyWith<_$FulltextChapterImpl> get copyWith =>
      __$$FulltextChapterImplCopyWithImpl<_$FulltextChapterImpl>(
        this,
        _$identity,
      );

  @override
  Map<String, dynamic> toJson() {
    return _$$FulltextChapterImplToJson(this);
  }
}

abstract class _FulltextChapter extends FulltextChapter {
  const factory _FulltextChapter({
    @JsonKey(fromJson: _flexInt) required final int index,
    final String? name,
    required final String text,
    final String? html,
    final String? css,
    final int? charCount,
    final List<FulltextSegment>? segments,
  }) = _$FulltextChapterImpl;
  const _FulltextChapter._() : super._();

  factory _FulltextChapter.fromJson(Map<String, dynamic> json) =
      _$FulltextChapterImpl.fromJson;

  @override
  @JsonKey(fromJson: _flexInt)
  int get index;
  @override
  String? get name;
  @override
  String get text;
  @override
  String? get html;
  @override
  String? get css;
  @override
  int? get charCount;
  @override
  List<FulltextSegment>? get segments;

  /// Create a copy of FulltextChapter
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$FulltextChapterImplCopyWith<_$FulltextChapterImpl> get copyWith =>
      throw _privateConstructorUsedError;
}

EbookFulltext _$EbookFulltextFromJson(Map<String, dynamic> json) {
  return _EbookFulltext.fromJson(json);
}

/// @nodoc
mixin _$EbookFulltext {
  String get jobId => throw _privateConstructorUsedError;
  String? get bookTitle => throw _privateConstructorUsedError;
  String? get bookAuthor => throw _privateConstructorUsedError;
  List<FulltextChapter> get chapters => throw _privateConstructorUsedError;

  /// Serializes this EbookFulltext to a JSON map.
  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;

  /// Create a copy of EbookFulltext
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $EbookFulltextCopyWith<EbookFulltext> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $EbookFulltextCopyWith<$Res> {
  factory $EbookFulltextCopyWith(
    EbookFulltext value,
    $Res Function(EbookFulltext) then,
  ) = _$EbookFulltextCopyWithImpl<$Res, EbookFulltext>;
  @useResult
  $Res call({
    String jobId,
    String? bookTitle,
    String? bookAuthor,
    List<FulltextChapter> chapters,
  });
}

/// @nodoc
class _$EbookFulltextCopyWithImpl<$Res, $Val extends EbookFulltext>
    implements $EbookFulltextCopyWith<$Res> {
  _$EbookFulltextCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of EbookFulltext
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? jobId = null,
    Object? bookTitle = freezed,
    Object? bookAuthor = freezed,
    Object? chapters = null,
  }) {
    return _then(
      _value.copyWith(
            jobId: null == jobId
                ? _value.jobId
                : jobId // ignore: cast_nullable_to_non_nullable
                      as String,
            bookTitle: freezed == bookTitle
                ? _value.bookTitle
                : bookTitle // ignore: cast_nullable_to_non_nullable
                      as String?,
            bookAuthor: freezed == bookAuthor
                ? _value.bookAuthor
                : bookAuthor // ignore: cast_nullable_to_non_nullable
                      as String?,
            chapters: null == chapters
                ? _value.chapters
                : chapters // ignore: cast_nullable_to_non_nullable
                      as List<FulltextChapter>,
          )
          as $Val,
    );
  }
}

/// @nodoc
abstract class _$$EbookFulltextImplCopyWith<$Res>
    implements $EbookFulltextCopyWith<$Res> {
  factory _$$EbookFulltextImplCopyWith(
    _$EbookFulltextImpl value,
    $Res Function(_$EbookFulltextImpl) then,
  ) = __$$EbookFulltextImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({
    String jobId,
    String? bookTitle,
    String? bookAuthor,
    List<FulltextChapter> chapters,
  });
}

/// @nodoc
class __$$EbookFulltextImplCopyWithImpl<$Res>
    extends _$EbookFulltextCopyWithImpl<$Res, _$EbookFulltextImpl>
    implements _$$EbookFulltextImplCopyWith<$Res> {
  __$$EbookFulltextImplCopyWithImpl(
    _$EbookFulltextImpl _value,
    $Res Function(_$EbookFulltextImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of EbookFulltext
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? jobId = null,
    Object? bookTitle = freezed,
    Object? bookAuthor = freezed,
    Object? chapters = null,
  }) {
    return _then(
      _$EbookFulltextImpl(
        jobId: null == jobId
            ? _value.jobId
            : jobId // ignore: cast_nullable_to_non_nullable
                  as String,
        bookTitle: freezed == bookTitle
            ? _value.bookTitle
            : bookTitle // ignore: cast_nullable_to_non_nullable
                  as String?,
        bookAuthor: freezed == bookAuthor
            ? _value.bookAuthor
            : bookAuthor // ignore: cast_nullable_to_non_nullable
                  as String?,
        chapters: null == chapters
            ? _value._chapters
            : chapters // ignore: cast_nullable_to_non_nullable
                  as List<FulltextChapter>,
      ),
    );
  }
}

/// @nodoc
@JsonSerializable()
class _$EbookFulltextImpl implements _EbookFulltext {
  const _$EbookFulltextImpl({
    required this.jobId,
    this.bookTitle,
    this.bookAuthor,
    required final List<FulltextChapter> chapters,
  }) : _chapters = chapters;

  factory _$EbookFulltextImpl.fromJson(Map<String, dynamic> json) =>
      _$$EbookFulltextImplFromJson(json);

  @override
  final String jobId;
  @override
  final String? bookTitle;
  @override
  final String? bookAuthor;
  final List<FulltextChapter> _chapters;
  @override
  List<FulltextChapter> get chapters {
    if (_chapters is EqualUnmodifiableListView) return _chapters;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_chapters);
  }

  @override
  String toString() {
    return 'EbookFulltext(jobId: $jobId, bookTitle: $bookTitle, bookAuthor: $bookAuthor, chapters: $chapters)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$EbookFulltextImpl &&
            (identical(other.jobId, jobId) || other.jobId == jobId) &&
            (identical(other.bookTitle, bookTitle) ||
                other.bookTitle == bookTitle) &&
            (identical(other.bookAuthor, bookAuthor) ||
                other.bookAuthor == bookAuthor) &&
            const DeepCollectionEquality().equals(other._chapters, _chapters));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
    runtimeType,
    jobId,
    bookTitle,
    bookAuthor,
    const DeepCollectionEquality().hash(_chapters),
  );

  /// Create a copy of EbookFulltext
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$EbookFulltextImplCopyWith<_$EbookFulltextImpl> get copyWith =>
      __$$EbookFulltextImplCopyWithImpl<_$EbookFulltextImpl>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$$EbookFulltextImplToJson(this);
  }
}

abstract class _EbookFulltext implements EbookFulltext {
  const factory _EbookFulltext({
    required final String jobId,
    final String? bookTitle,
    final String? bookAuthor,
    required final List<FulltextChapter> chapters,
  }) = _$EbookFulltextImpl;

  factory _EbookFulltext.fromJson(Map<String, dynamic> json) =
      _$EbookFulltextImpl.fromJson;

  @override
  String get jobId;
  @override
  String? get bookTitle;
  @override
  String? get bookAuthor;
  @override
  List<FulltextChapter> get chapters;

  /// Create a copy of EbookFulltext
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$EbookFulltextImplCopyWith<_$EbookFulltextImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
