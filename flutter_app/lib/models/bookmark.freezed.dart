// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'bookmark.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
  'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models',
);

Bookmark _$BookmarkFromJson(Map<String, dynamic> json) {
  return _Bookmark.fromJson(json);
}

/// @nodoc
mixin _$Bookmark {
  String get id => throw _privateConstructorUsedError;
  set id(String value) => throw _privateConstructorUsedError;
  String get bookId => throw _privateConstructorUsedError;
  set bookId(String value) => throw _privateConstructorUsedError;
  int get chapterIndex => throw _privateConstructorUsedError;
  set chapterIndex(int value) => throw _privateConstructorUsedError;
  String get chapterTitle => throw _privateConstructorUsedError;
  set chapterTitle(String value) => throw _privateConstructorUsedError;
  int get startChar => throw _privateConstructorUsedError;
  set startChar(int value) => throw _privateConstructorUsedError;
  int get endChar => throw _privateConstructorUsedError;
  set endChar(int value) => throw _privateConstructorUsedError;
  String get selectedText => throw _privateConstructorUsedError;
  set selectedText(String value) => throw _privateConstructorUsedError;
  String? get note => throw _privateConstructorUsedError;
  set note(String? value) => throw _privateConstructorUsedError;
  HighlightColor get color => throw _privateConstructorUsedError;
  set color(HighlightColor value) => throw _privateConstructorUsedError;
  DateTime get createdAt => throw _privateConstructorUsedError;
  set createdAt(DateTime value) => throw _privateConstructorUsedError;

  /// Serializes this Bookmark to a JSON map.
  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;

  /// Create a copy of Bookmark
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $BookmarkCopyWith<Bookmark> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $BookmarkCopyWith<$Res> {
  factory $BookmarkCopyWith(Bookmark value, $Res Function(Bookmark) then) =
      _$BookmarkCopyWithImpl<$Res, Bookmark>;
  @useResult
  $Res call({
    String id,
    String bookId,
    int chapterIndex,
    String chapterTitle,
    int startChar,
    int endChar,
    String selectedText,
    String? note,
    HighlightColor color,
    DateTime createdAt,
  });
}

/// @nodoc
class _$BookmarkCopyWithImpl<$Res, $Val extends Bookmark>
    implements $BookmarkCopyWith<$Res> {
  _$BookmarkCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of Bookmark
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? id = null,
    Object? bookId = null,
    Object? chapterIndex = null,
    Object? chapterTitle = null,
    Object? startChar = null,
    Object? endChar = null,
    Object? selectedText = null,
    Object? note = freezed,
    Object? color = null,
    Object? createdAt = null,
  }) {
    return _then(
      _value.copyWith(
            id: null == id
                ? _value.id
                : id // ignore: cast_nullable_to_non_nullable
                      as String,
            bookId: null == bookId
                ? _value.bookId
                : bookId // ignore: cast_nullable_to_non_nullable
                      as String,
            chapterIndex: null == chapterIndex
                ? _value.chapterIndex
                : chapterIndex // ignore: cast_nullable_to_non_nullable
                      as int,
            chapterTitle: null == chapterTitle
                ? _value.chapterTitle
                : chapterTitle // ignore: cast_nullable_to_non_nullable
                      as String,
            startChar: null == startChar
                ? _value.startChar
                : startChar // ignore: cast_nullable_to_non_nullable
                      as int,
            endChar: null == endChar
                ? _value.endChar
                : endChar // ignore: cast_nullable_to_non_nullable
                      as int,
            selectedText: null == selectedText
                ? _value.selectedText
                : selectedText // ignore: cast_nullable_to_non_nullable
                      as String,
            note: freezed == note
                ? _value.note
                : note // ignore: cast_nullable_to_non_nullable
                      as String?,
            color: null == color
                ? _value.color
                : color // ignore: cast_nullable_to_non_nullable
                      as HighlightColor,
            createdAt: null == createdAt
                ? _value.createdAt
                : createdAt // ignore: cast_nullable_to_non_nullable
                      as DateTime,
          )
          as $Val,
    );
  }
}

/// @nodoc
abstract class _$$BookmarkImplCopyWith<$Res>
    implements $BookmarkCopyWith<$Res> {
  factory _$$BookmarkImplCopyWith(
    _$BookmarkImpl value,
    $Res Function(_$BookmarkImpl) then,
  ) = __$$BookmarkImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({
    String id,
    String bookId,
    int chapterIndex,
    String chapterTitle,
    int startChar,
    int endChar,
    String selectedText,
    String? note,
    HighlightColor color,
    DateTime createdAt,
  });
}

/// @nodoc
class __$$BookmarkImplCopyWithImpl<$Res>
    extends _$BookmarkCopyWithImpl<$Res, _$BookmarkImpl>
    implements _$$BookmarkImplCopyWith<$Res> {
  __$$BookmarkImplCopyWithImpl(
    _$BookmarkImpl _value,
    $Res Function(_$BookmarkImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of Bookmark
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? id = null,
    Object? bookId = null,
    Object? chapterIndex = null,
    Object? chapterTitle = null,
    Object? startChar = null,
    Object? endChar = null,
    Object? selectedText = null,
    Object? note = freezed,
    Object? color = null,
    Object? createdAt = null,
  }) {
    return _then(
      _$BookmarkImpl(
        id: null == id
            ? _value.id
            : id // ignore: cast_nullable_to_non_nullable
                  as String,
        bookId: null == bookId
            ? _value.bookId
            : bookId // ignore: cast_nullable_to_non_nullable
                  as String,
        chapterIndex: null == chapterIndex
            ? _value.chapterIndex
            : chapterIndex // ignore: cast_nullable_to_non_nullable
                  as int,
        chapterTitle: null == chapterTitle
            ? _value.chapterTitle
            : chapterTitle // ignore: cast_nullable_to_non_nullable
                  as String,
        startChar: null == startChar
            ? _value.startChar
            : startChar // ignore: cast_nullable_to_non_nullable
                  as int,
        endChar: null == endChar
            ? _value.endChar
            : endChar // ignore: cast_nullable_to_non_nullable
                  as int,
        selectedText: null == selectedText
            ? _value.selectedText
            : selectedText // ignore: cast_nullable_to_non_nullable
                  as String,
        note: freezed == note
            ? _value.note
            : note // ignore: cast_nullable_to_non_nullable
                  as String?,
        color: null == color
            ? _value.color
            : color // ignore: cast_nullable_to_non_nullable
                  as HighlightColor,
        createdAt: null == createdAt
            ? _value.createdAt
            : createdAt // ignore: cast_nullable_to_non_nullable
                  as DateTime,
      ),
    );
  }
}

/// @nodoc
@JsonSerializable()
class _$BookmarkImpl extends _Bookmark {
  _$BookmarkImpl({
    required this.id,
    required this.bookId,
    required this.chapterIndex,
    required this.chapterTitle,
    this.startChar = 0,
    this.endChar = 0,
    this.selectedText = '',
    this.note,
    this.color = HighlightColor.yellow,
    required this.createdAt,
  }) : super._();

  factory _$BookmarkImpl.fromJson(Map<String, dynamic> json) =>
      _$$BookmarkImplFromJson(json);

  @override
  String id;
  @override
  String bookId;
  @override
  int chapterIndex;
  @override
  String chapterTitle;
  @override
  @JsonKey()
  int startChar;
  @override
  @JsonKey()
  int endChar;
  @override
  @JsonKey()
  String selectedText;
  @override
  String? note;
  @override
  @JsonKey()
  HighlightColor color;
  @override
  DateTime createdAt;

  @override
  String toString() {
    return 'Bookmark(id: $id, bookId: $bookId, chapterIndex: $chapterIndex, chapterTitle: $chapterTitle, startChar: $startChar, endChar: $endChar, selectedText: $selectedText, note: $note, color: $color, createdAt: $createdAt)';
  }

  /// Create a copy of Bookmark
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$BookmarkImplCopyWith<_$BookmarkImpl> get copyWith =>
      __$$BookmarkImplCopyWithImpl<_$BookmarkImpl>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$$BookmarkImplToJson(this);
  }
}

abstract class _Bookmark extends Bookmark {
  factory _Bookmark({
    required String id,
    required String bookId,
    required int chapterIndex,
    required String chapterTitle,
    int startChar,
    int endChar,
    String selectedText,
    String? note,
    HighlightColor color,
    required DateTime createdAt,
  }) = _$BookmarkImpl;
  _Bookmark._() : super._();

  factory _Bookmark.fromJson(Map<String, dynamic> json) =
      _$BookmarkImpl.fromJson;

  @override
  String get id;
  set id(String value);
  @override
  String get bookId;
  set bookId(String value);
  @override
  int get chapterIndex;
  set chapterIndex(int value);
  @override
  String get chapterTitle;
  set chapterTitle(String value);
  @override
  int get startChar;
  set startChar(int value);
  @override
  int get endChar;
  set endChar(int value);
  @override
  String get selectedText;
  set selectedText(String value);
  @override
  String? get note;
  set note(String? value);
  @override
  HighlightColor get color;
  set color(HighlightColor value);
  @override
  DateTime get createdAt;
  set createdAt(DateTime value);

  /// Create a copy of Bookmark
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$BookmarkImplCopyWith<_$BookmarkImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
