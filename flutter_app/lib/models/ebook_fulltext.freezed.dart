// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'ebook_fulltext.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$SentenceSpan {
  String get id;
  String get text;
  int get startChar;
  int get endChar;

  /// Create a copy of SentenceSpan
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $SentenceSpanCopyWith<SentenceSpan> get copyWith =>
      _$SentenceSpanCopyWithImpl<SentenceSpan>(
        this as SentenceSpan,
        _$identity,
      );

  @override
  bool operator ==(Object other) {
    final _this = this as SentenceSpan;
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is SentenceSpan &&
            (identical(other.id, _this.id) || other.id == _this.id) &&
            (identical(other.text, _this.text) || other.text == _this.text) &&
            (identical(other.startChar, _this.startChar) ||
                other.startChar == _this.startChar) &&
            (identical(other.endChar, _this.endChar) ||
                other.endChar == _this.endChar));
  }

  @override
  int get hashCode {
    final _this = this as SentenceSpan;
    return Object.hash(
      runtimeType,
      _this.id,
      _this.text,
      _this.startChar,
      _this.endChar,
    );
  }

  @override
  String toString() {
    final _this = this as SentenceSpan;
    return 'SentenceSpan(id: ${_this.id}, text: ${_this.text}, startChar: ${_this.startChar}, endChar: ${_this.endChar})';
  }
}

/// @nodoc
abstract mixin class $SentenceSpanCopyWith<$Res> {
  factory $SentenceSpanCopyWith(
    SentenceSpan value,
    $Res Function(SentenceSpan) _then,
  ) = _$SentenceSpanCopyWithImpl;
  @useResult
  $Res call({String id, String text, int startChar, int endChar});
}

/// @nodoc
class _$SentenceSpanCopyWithImpl<$Res> implements $SentenceSpanCopyWith<$Res> {
  _$SentenceSpanCopyWithImpl(this._self, this._then);

  final SentenceSpan _self;
  final $Res Function(SentenceSpan) _then;

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
      SentenceSpan(
        id: null == id
            ? _self.id
            : id // ignore: cast_nullable_to_non_nullable
                  as String,
        text: null == text
            ? _self.text
            : text // ignore: cast_nullable_to_non_nullable
                  as String,
        startChar: null == startChar
            ? _self.startChar
            : startChar // ignore: cast_nullable_to_non_nullable
                  as int,
        endChar: null == endChar
            ? _self.endChar
            : endChar // ignore: cast_nullable_to_non_nullable
                  as int,
      ),
    );
  }
}

/// Adds pattern-matching-related methods to [SentenceSpan].
extension SentenceSpanPatterns on SentenceSpan {
  /// A variant of `map` that fallback to returning `orElse`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>(
    TResult Function(_SentenceSpan value)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _SentenceSpan() when $default != null:
        return $default(_that);
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// Callbacks receives the raw object, upcasted.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case final Subclass2 value:
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult map<TResult extends Object?>(
    TResult Function(_SentenceSpan value) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _SentenceSpan():
        return $default(_that);
      case _:
        throw StateError('Unexpected subclass');
    }
  }

  /// A variant of `map` that fallback to returning `null`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>(
    TResult? Function(_SentenceSpan value)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _SentenceSpan() when $default != null:
        return $default(_that);
      case _:
        return null;
    }
  }

  /// A variant of `when` that fallback to an `orElse` callback.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>(
    TResult Function(String id, String text, int startChar, int endChar)?
    $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _SentenceSpan() when $default != null:
        return $default(_that.id, _that.text, _that.startChar, _that.endChar);
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// As opposed to `map`, this offers destructuring.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case Subclass2(:final field2):
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult when<TResult extends Object?>(
    TResult Function(String id, String text, int startChar, int endChar)
    $default,
  ) {
    final _that = this;
    switch (_that) {
      case _SentenceSpan():
        return $default(_that.id, _that.text, _that.startChar, _that.endChar);
      case _:
        throw StateError('Unexpected subclass');
    }
  }

  /// A variant of `when` that fallback to returning `null`
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>(
    TResult? Function(String id, String text, int startChar, int endChar)?
    $default,
  ) {
    final _that = this;
    switch (_that) {
      case _SentenceSpan() when $default != null:
        return $default(_that.id, _that.text, _that.startChar, _that.endChar);
      case _:
        return null;
    }
  }
}

/// @nodoc

class _SentenceSpan implements SentenceSpan {
  const _SentenceSpan({
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

  /// Create a copy of SentenceSpan
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$SentenceSpanCopyWith<_SentenceSpan> get copyWith =>
      __$SentenceSpanCopyWithImpl<_SentenceSpan>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _SentenceSpan &&
            (identical(other.id, id) || other.id == id) &&
            (identical(other.text, text) || other.text == text) &&
            (identical(other.startChar, startChar) ||
                other.startChar == startChar) &&
            (identical(other.endChar, endChar) || other.endChar == endChar));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, id, text, startChar, endChar);
  }

  @override
  String toString() {
    return 'SentenceSpan(id: $id, text: $text, startChar: $startChar, endChar: $endChar)';
  }
}

/// @nodoc
abstract mixin class _$SentenceSpanCopyWith<$Res>
    implements $SentenceSpanCopyWith<$Res> {
  factory _$SentenceSpanCopyWith(
    _SentenceSpan value,
    $Res Function(_SentenceSpan) _then,
  ) = __$SentenceSpanCopyWithImpl;
  @override
  @useResult
  $Res call({String id, String text, int startChar, int endChar});
}

/// @nodoc
class __$SentenceSpanCopyWithImpl<$Res>
    implements _$SentenceSpanCopyWith<$Res> {
  __$SentenceSpanCopyWithImpl(this._self, this._then);

  final _SentenceSpan _self;
  final $Res Function(_SentenceSpan) _then;

  /// Create a copy of SentenceSpan
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? id = null,
    Object? text = null,
    Object? startChar = null,
    Object? endChar = null,
  }) {
    return _then(
      _SentenceSpan(
        id: null == id
            ? _self.id
            : id // ignore: cast_nullable_to_non_nullable
                  as String,
        text: null == text
            ? _self.text
            : text // ignore: cast_nullable_to_non_nullable
                  as String,
        startChar: null == startChar
            ? _self.startChar
            : startChar // ignore: cast_nullable_to_non_nullable
                  as int,
        endChar: null == endChar
            ? _self.endChar
            : endChar // ignore: cast_nullable_to_non_nullable
                  as int,
      ),
    );
  }
}

/// @nodoc
mixin _$FulltextSegment {
  String? get id;
  String get text;
  int? get startMs;
  int? get endMs;

  /// Create a copy of FulltextSegment
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $FulltextSegmentCopyWith<FulltextSegment> get copyWith =>
      _$FulltextSegmentCopyWithImpl<FulltextSegment>(
        this as FulltextSegment,
        _$identity,
      );

  /// Serializes this FulltextSegment to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    final _this = this as FulltextSegment;
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is FulltextSegment &&
            (identical(other.id, _this.id) || other.id == _this.id) &&
            (identical(other.text, _this.text) || other.text == _this.text) &&
            (identical(other.startMs, _this.startMs) ||
                other.startMs == _this.startMs) &&
            (identical(other.endMs, _this.endMs) ||
                other.endMs == _this.endMs));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode {
    final _this = this as FulltextSegment;
    return Object.hash(
      runtimeType,
      _this.id,
      _this.text,
      _this.startMs,
      _this.endMs,
    );
  }

  @override
  String toString() {
    final _this = this as FulltextSegment;
    return 'FulltextSegment(id: ${_this.id}, text: ${_this.text}, startMs: ${_this.startMs}, endMs: ${_this.endMs})';
  }
}

/// @nodoc
abstract mixin class $FulltextSegmentCopyWith<$Res> {
  factory $FulltextSegmentCopyWith(
    FulltextSegment value,
    $Res Function(FulltextSegment) _then,
  ) = _$FulltextSegmentCopyWithImpl;
  @useResult
  $Res call({String? id, String text, int? startMs, int? endMs});
}

/// @nodoc
class _$FulltextSegmentCopyWithImpl<$Res>
    implements $FulltextSegmentCopyWith<$Res> {
  _$FulltextSegmentCopyWithImpl(this._self, this._then);

  final FulltextSegment _self;
  final $Res Function(FulltextSegment) _then;

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
      FulltextSegment(
        id: freezed == id
            ? _self.id
            : id // ignore: cast_nullable_to_non_nullable
                  as String?,
        text: null == text
            ? _self.text
            : text // ignore: cast_nullable_to_non_nullable
                  as String,
        startMs: freezed == startMs
            ? _self.startMs
            : startMs // ignore: cast_nullable_to_non_nullable
                  as int?,
        endMs: freezed == endMs
            ? _self.endMs
            : endMs // ignore: cast_nullable_to_non_nullable
                  as int?,
      ),
    );
  }
}

/// Adds pattern-matching-related methods to [FulltextSegment].
extension FulltextSegmentPatterns on FulltextSegment {
  /// A variant of `map` that fallback to returning `orElse`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>(
    TResult Function(_FulltextSegment value)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _FulltextSegment() when $default != null:
        return $default(_that);
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// Callbacks receives the raw object, upcasted.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case final Subclass2 value:
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult map<TResult extends Object?>(
    TResult Function(_FulltextSegment value) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _FulltextSegment():
        return $default(_that);
      case _:
        throw StateError('Unexpected subclass');
    }
  }

  /// A variant of `map` that fallback to returning `null`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>(
    TResult? Function(_FulltextSegment value)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _FulltextSegment() when $default != null:
        return $default(_that);
      case _:
        return null;
    }
  }

  /// A variant of `when` that fallback to an `orElse` callback.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>(
    TResult Function(String? id, String text, int? startMs, int? endMs)?
    $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _FulltextSegment() when $default != null:
        return $default(_that.id, _that.text, _that.startMs, _that.endMs);
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// As opposed to `map`, this offers destructuring.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case Subclass2(:final field2):
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult when<TResult extends Object?>(
    TResult Function(String? id, String text, int? startMs, int? endMs)
    $default,
  ) {
    final _that = this;
    switch (_that) {
      case _FulltextSegment():
        return $default(_that.id, _that.text, _that.startMs, _that.endMs);
      case _:
        throw StateError('Unexpected subclass');
    }
  }

  /// A variant of `when` that fallback to returning `null`
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>(
    TResult? Function(String? id, String text, int? startMs, int? endMs)?
    $default,
  ) {
    final _that = this;
    switch (_that) {
      case _FulltextSegment() when $default != null:
        return $default(_that.id, _that.text, _that.startMs, _that.endMs);
      case _:
        return null;
    }
  }
}

/// @nodoc
@JsonSerializable()
class _FulltextSegment implements FulltextSegment {
  const _FulltextSegment({
    this.id,
    required this.text,
    this.startMs,
    this.endMs,
  });
  factory _FulltextSegment.fromJson(Map<String, dynamic> json) =>
      _$FulltextSegmentFromJson(json);

  @override
  final String? id;
  @override
  final String text;
  @override
  final int? startMs;
  @override
  final int? endMs;

  /// Create a copy of FulltextSegment
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$FulltextSegmentCopyWith<_FulltextSegment> get copyWith =>
      __$FulltextSegmentCopyWithImpl<_FulltextSegment>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$FulltextSegmentToJson(this);
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _FulltextSegment &&
            (identical(other.id, id) || other.id == id) &&
            (identical(other.text, text) || other.text == text) &&
            (identical(other.startMs, startMs) || other.startMs == startMs) &&
            (identical(other.endMs, endMs) || other.endMs == endMs));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode {
    return Object.hash(runtimeType, id, text, startMs, endMs);
  }

  @override
  String toString() {
    return 'FulltextSegment(id: $id, text: $text, startMs: $startMs, endMs: $endMs)';
  }
}

/// @nodoc
abstract mixin class _$FulltextSegmentCopyWith<$Res>
    implements $FulltextSegmentCopyWith<$Res> {
  factory _$FulltextSegmentCopyWith(
    _FulltextSegment value,
    $Res Function(_FulltextSegment) _then,
  ) = __$FulltextSegmentCopyWithImpl;
  @override
  @useResult
  $Res call({String? id, String text, int? startMs, int? endMs});
}

/// @nodoc
class __$FulltextSegmentCopyWithImpl<$Res>
    implements _$FulltextSegmentCopyWith<$Res> {
  __$FulltextSegmentCopyWithImpl(this._self, this._then);

  final _FulltextSegment _self;
  final $Res Function(_FulltextSegment) _then;

  /// Create a copy of FulltextSegment
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? id = freezed,
    Object? text = null,
    Object? startMs = freezed,
    Object? endMs = freezed,
  }) {
    return _then(
      _FulltextSegment(
        id: freezed == id
            ? _self.id
            : id // ignore: cast_nullable_to_non_nullable
                  as String?,
        text: null == text
            ? _self.text
            : text // ignore: cast_nullable_to_non_nullable
                  as String,
        startMs: freezed == startMs
            ? _self.startMs
            : startMs // ignore: cast_nullable_to_non_nullable
                  as int?,
        endMs: freezed == endMs
            ? _self.endMs
            : endMs // ignore: cast_nullable_to_non_nullable
                  as int?,
      ),
    );
  }
}

/// @nodoc
mixin _$FulltextFootnote {
  String? get number;
  String get text;

  /// Create a copy of FulltextFootnote
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $FulltextFootnoteCopyWith<FulltextFootnote> get copyWith =>
      _$FulltextFootnoteCopyWithImpl<FulltextFootnote>(
        this as FulltextFootnote,
        _$identity,
      );

  /// Serializes this FulltextFootnote to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    final _this = this as FulltextFootnote;
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is FulltextFootnote &&
            (identical(other.number, _this.number) ||
                other.number == _this.number) &&
            (identical(other.text, _this.text) || other.text == _this.text));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode {
    final _this = this as FulltextFootnote;
    return Object.hash(runtimeType, _this.number, _this.text);
  }

  @override
  String toString() {
    final _this = this as FulltextFootnote;
    return 'FulltextFootnote(number: ${_this.number}, text: ${_this.text})';
  }
}

/// @nodoc
abstract mixin class $FulltextFootnoteCopyWith<$Res> {
  factory $FulltextFootnoteCopyWith(
    FulltextFootnote value,
    $Res Function(FulltextFootnote) _then,
  ) = _$FulltextFootnoteCopyWithImpl;
  @useResult
  $Res call({String? number, String text});
}

/// @nodoc
class _$FulltextFootnoteCopyWithImpl<$Res>
    implements $FulltextFootnoteCopyWith<$Res> {
  _$FulltextFootnoteCopyWithImpl(this._self, this._then);

  final FulltextFootnote _self;
  final $Res Function(FulltextFootnote) _then;

  /// Create a copy of FulltextFootnote
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({Object? number = freezed, Object? text = null}) {
    return _then(
      FulltextFootnote(
        number: freezed == number
            ? _self.number
            : number // ignore: cast_nullable_to_non_nullable
                  as String?,
        text: null == text
            ? _self.text
            : text // ignore: cast_nullable_to_non_nullable
                  as String,
      ),
    );
  }
}

/// Adds pattern-matching-related methods to [FulltextFootnote].
extension FulltextFootnotePatterns on FulltextFootnote {
  /// A variant of `map` that fallback to returning `orElse`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>(
    TResult Function(_FulltextFootnote value)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _FulltextFootnote() when $default != null:
        return $default(_that);
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// Callbacks receives the raw object, upcasted.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case final Subclass2 value:
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult map<TResult extends Object?>(
    TResult Function(_FulltextFootnote value) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _FulltextFootnote():
        return $default(_that);
      case _:
        throw StateError('Unexpected subclass');
    }
  }

  /// A variant of `map` that fallback to returning `null`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>(
    TResult? Function(_FulltextFootnote value)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _FulltextFootnote() when $default != null:
        return $default(_that);
      case _:
        return null;
    }
  }

  /// A variant of `when` that fallback to an `orElse` callback.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>(
    TResult Function(String? number, String text)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _FulltextFootnote() when $default != null:
        return $default(_that.number, _that.text);
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// As opposed to `map`, this offers destructuring.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case Subclass2(:final field2):
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult when<TResult extends Object?>(
    TResult Function(String? number, String text) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _FulltextFootnote():
        return $default(_that.number, _that.text);
      case _:
        throw StateError('Unexpected subclass');
    }
  }

  /// A variant of `when` that fallback to returning `null`
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>(
    TResult? Function(String? number, String text)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _FulltextFootnote() when $default != null:
        return $default(_that.number, _that.text);
      case _:
        return null;
    }
  }
}

/// @nodoc
@JsonSerializable()
class _FulltextFootnote implements FulltextFootnote {
  const _FulltextFootnote({this.number, required this.text});
  factory _FulltextFootnote.fromJson(Map<String, dynamic> json) =>
      _$FulltextFootnoteFromJson(json);

  @override
  final String? number;
  @override
  final String text;

  /// Create a copy of FulltextFootnote
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$FulltextFootnoteCopyWith<_FulltextFootnote> get copyWith =>
      __$FulltextFootnoteCopyWithImpl<_FulltextFootnote>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$FulltextFootnoteToJson(this);
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _FulltextFootnote &&
            (identical(other.number, number) || other.number == number) &&
            (identical(other.text, text) || other.text == text));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode {
    return Object.hash(runtimeType, number, text);
  }

  @override
  String toString() {
    return 'FulltextFootnote(number: $number, text: $text)';
  }
}

/// @nodoc
abstract mixin class _$FulltextFootnoteCopyWith<$Res>
    implements $FulltextFootnoteCopyWith<$Res> {
  factory _$FulltextFootnoteCopyWith(
    _FulltextFootnote value,
    $Res Function(_FulltextFootnote) _then,
  ) = __$FulltextFootnoteCopyWithImpl;
  @override
  @useResult
  $Res call({String? number, String text});
}

/// @nodoc
class __$FulltextFootnoteCopyWithImpl<$Res>
    implements _$FulltextFootnoteCopyWith<$Res> {
  __$FulltextFootnoteCopyWithImpl(this._self, this._then);

  final _FulltextFootnote _self;
  final $Res Function(_FulltextFootnote) _then;

  /// Create a copy of FulltextFootnote
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({Object? number = freezed, Object? text = null}) {
    return _then(
      _FulltextFootnote(
        number: freezed == number
            ? _self.number
            : number // ignore: cast_nullable_to_non_nullable
                  as String?,
        text: null == text
            ? _self.text
            : text // ignore: cast_nullable_to_non_nullable
                  as String,
      ),
    );
  }
}

/// @nodoc
mixin _$FulltextChapter {
  @JsonKey(fromJson: _flexInt)
  int get index;
  String? get name;
  String get text;
  String? get html;
  String? get css;
  int? get charCount;
  List<FulltextSegment>? get segments;
  List<FulltextFootnote>? get footnotes;

  /// TOC fragment id -> scalar offset inside [text]; absent when the book has none.
  Map<String, int>? get anchors;

  /// Where the chapter starts in the source: an EPUB file path, or `page-N` for a PDF.
  String? get sourcePath;

  /// Create a copy of FulltextChapter
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $FulltextChapterCopyWith<FulltextChapter> get copyWith =>
      _$FulltextChapterCopyWithImpl<FulltextChapter>(
        this as FulltextChapter,
        _$identity,
      );

  /// Serializes this FulltextChapter to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    final _this = this as FulltextChapter;
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is FulltextChapter &&
            (identical(other.index, _this.index) ||
                other.index == _this.index) &&
            (identical(other.name, _this.name) || other.name == _this.name) &&
            (identical(other.text, _this.text) || other.text == _this.text) &&
            (identical(other.html, _this.html) || other.html == _this.html) &&
            (identical(other.css, _this.css) || other.css == _this.css) &&
            (identical(other.charCount, _this.charCount) ||
                other.charCount == _this.charCount) &&
            const DeepCollectionEquality().equals(
              other.segments,
              _this.segments,
            ) &&
            const DeepCollectionEquality().equals(
              other.footnotes,
              _this.footnotes,
            ) &&
            const DeepCollectionEquality().equals(
              other.anchors,
              _this.anchors,
            ) &&
            (identical(other.sourcePath, _this.sourcePath) ||
                other.sourcePath == _this.sourcePath));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode {
    final _this = this as FulltextChapter;
    return Object.hash(
      runtimeType,
      _this.index,
      _this.name,
      _this.text,
      _this.html,
      _this.css,
      _this.charCount,
      const DeepCollectionEquality().hash(_this.segments),
      const DeepCollectionEquality().hash(_this.footnotes),
      const DeepCollectionEquality().hash(_this.anchors),
      _this.sourcePath,
    );
  }

  @override
  String toString() {
    final _this = this as FulltextChapter;
    return 'FulltextChapter(index: ${_this.index}, name: ${_this.name}, text: ${_this.text}, html: ${_this.html}, css: ${_this.css}, charCount: ${_this.charCount}, segments: ${_this.segments}, footnotes: ${_this.footnotes}, anchors: ${_this.anchors}, sourcePath: ${_this.sourcePath})';
  }
}

/// @nodoc
abstract mixin class $FulltextChapterCopyWith<$Res> {
  factory $FulltextChapterCopyWith(
    FulltextChapter value,
    $Res Function(FulltextChapter) _then,
  ) = _$FulltextChapterCopyWithImpl;
  @useResult
  $Res call({
    @JsonKey(fromJson: _flexInt) int index,
    String? name,
    String text,
    String? html,
    String? css,
    int? charCount,
    List<FulltextSegment>? segments,
    List<FulltextFootnote>? footnotes,
    Map<String, int>? anchors,
    String? sourcePath,
  });
}

/// @nodoc
class _$FulltextChapterCopyWithImpl<$Res>
    implements $FulltextChapterCopyWith<$Res> {
  _$FulltextChapterCopyWithImpl(this._self, this._then);

  final FulltextChapter _self;
  final $Res Function(FulltextChapter) _then;

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
    Object? footnotes = freezed,
    Object? anchors = freezed,
    Object? sourcePath = freezed,
  }) {
    return _then(
      FulltextChapter(
        index: null == index
            ? _self.index
            : index // ignore: cast_nullable_to_non_nullable
                  as int,
        name: freezed == name
            ? _self.name
            : name // ignore: cast_nullable_to_non_nullable
                  as String?,
        text: null == text
            ? _self.text
            : text // ignore: cast_nullable_to_non_nullable
                  as String,
        html: freezed == html
            ? _self.html
            : html // ignore: cast_nullable_to_non_nullable
                  as String?,
        css: freezed == css
            ? _self.css
            : css // ignore: cast_nullable_to_non_nullable
                  as String?,
        charCount: freezed == charCount
            ? _self.charCount
            : charCount // ignore: cast_nullable_to_non_nullable
                  as int?,
        segments: freezed == segments
            ? _self.segments
            : segments // ignore: cast_nullable_to_non_nullable
                  as List<FulltextSegment>?,
        footnotes: freezed == footnotes
            ? _self.footnotes
            : footnotes // ignore: cast_nullable_to_non_nullable
                  as List<FulltextFootnote>?,
        anchors: freezed == anchors
            ? _self.anchors
            : anchors // ignore: cast_nullable_to_non_nullable
                  as Map<String, int>?,
        sourcePath: freezed == sourcePath
            ? _self.sourcePath
            : sourcePath // ignore: cast_nullable_to_non_nullable
                  as String?,
      ),
    );
  }
}

/// Adds pattern-matching-related methods to [FulltextChapter].
extension FulltextChapterPatterns on FulltextChapter {
  /// A variant of `map` that fallback to returning `orElse`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>(
    TResult Function(_FulltextChapter value)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _FulltextChapter() when $default != null:
        return $default(_that);
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// Callbacks receives the raw object, upcasted.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case final Subclass2 value:
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult map<TResult extends Object?>(
    TResult Function(_FulltextChapter value) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _FulltextChapter():
        return $default(_that);
      case _:
        throw StateError('Unexpected subclass');
    }
  }

  /// A variant of `map` that fallback to returning `null`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>(
    TResult? Function(_FulltextChapter value)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _FulltextChapter() when $default != null:
        return $default(_that);
      case _:
        return null;
    }
  }

  /// A variant of `when` that fallback to an `orElse` callback.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>(
    TResult Function(
      @JsonKey(fromJson: _flexInt) int index,
      String? name,
      String text,
      String? html,
      String? css,
      int? charCount,
      List<FulltextSegment>? segments,
      List<FulltextFootnote>? footnotes,
      Map<String, int>? anchors,
      String? sourcePath,
    )?
    $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _FulltextChapter() when $default != null:
        return $default(
          _that.index,
          _that.name,
          _that.text,
          _that.html,
          _that.css,
          _that.charCount,
          _that.segments,
          _that.footnotes,
          _that.anchors,
          _that.sourcePath,
        );
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// As opposed to `map`, this offers destructuring.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case Subclass2(:final field2):
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult when<TResult extends Object?>(
    TResult Function(
      @JsonKey(fromJson: _flexInt) int index,
      String? name,
      String text,
      String? html,
      String? css,
      int? charCount,
      List<FulltextSegment>? segments,
      List<FulltextFootnote>? footnotes,
      Map<String, int>? anchors,
      String? sourcePath,
    )
    $default,
  ) {
    final _that = this;
    switch (_that) {
      case _FulltextChapter():
        return $default(
          _that.index,
          _that.name,
          _that.text,
          _that.html,
          _that.css,
          _that.charCount,
          _that.segments,
          _that.footnotes,
          _that.anchors,
          _that.sourcePath,
        );
      case _:
        throw StateError('Unexpected subclass');
    }
  }

  /// A variant of `when` that fallback to returning `null`
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>(
    TResult? Function(
      @JsonKey(fromJson: _flexInt) int index,
      String? name,
      String text,
      String? html,
      String? css,
      int? charCount,
      List<FulltextSegment>? segments,
      List<FulltextFootnote>? footnotes,
      Map<String, int>? anchors,
      String? sourcePath,
    )?
    $default,
  ) {
    final _that = this;
    switch (_that) {
      case _FulltextChapter() when $default != null:
        return $default(
          _that.index,
          _that.name,
          _that.text,
          _that.html,
          _that.css,
          _that.charCount,
          _that.segments,
          _that.footnotes,
          _that.anchors,
          _that.sourcePath,
        );
      case _:
        return null;
    }
  }
}

/// @nodoc
@JsonSerializable()
class _FulltextChapter extends FulltextChapter {
  const _FulltextChapter({
    @JsonKey(fromJson: _flexInt) required this.index,
    this.name,
    required this.text,
    this.html,
    this.css,
    this.charCount,
    List<FulltextSegment>? segments,
    List<FulltextFootnote>? footnotes,
    Map<String, int>? anchors,
    this.sourcePath,
  }) : _segments = segments,
       _footnotes = footnotes,
       _anchors = anchors,
       super._();
  factory _FulltextChapter.fromJson(Map<String, dynamic> json) =>
      _$FulltextChapterFromJson(json);

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

  final List<FulltextFootnote>? _footnotes;
  @override
  List<FulltextFootnote>? get footnotes {
    final value = _footnotes;
    if (value == null) return null;
    if (_footnotes is EqualUnmodifiableListView) return _footnotes;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(value);
  }

  /// TOC fragment id -> scalar offset inside [text]; absent when the book has none.
  final Map<String, int>? _anchors;

  /// TOC fragment id -> scalar offset inside [text]; absent when the book has none.
  @override
  Map<String, int>? get anchors {
    final value = _anchors;
    if (value == null) return null;
    if (_anchors is EqualUnmodifiableMapView) return _anchors;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableMapView(value);
  }

  /// Where the chapter starts in the source: an EPUB file path, or `page-N` for a PDF.
  @override
  final String? sourcePath;

  /// Create a copy of FulltextChapter
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$FulltextChapterCopyWith<_FulltextChapter> get copyWith =>
      __$FulltextChapterCopyWithImpl<_FulltextChapter>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$FulltextChapterToJson(this);
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _FulltextChapter &&
            (identical(other.index, index) || other.index == index) &&
            (identical(other.name, name) || other.name == name) &&
            (identical(other.text, text) || other.text == text) &&
            (identical(other.html, html) || other.html == html) &&
            (identical(other.css, css) || other.css == css) &&
            (identical(other.charCount, charCount) ||
                other.charCount == charCount) &&
            const DeepCollectionEquality().equals(other.segments, _segments) &&
            const DeepCollectionEquality().equals(
              other.footnotes,
              _footnotes,
            ) &&
            const DeepCollectionEquality().equals(other.anchors, _anchors) &&
            (identical(other.sourcePath, sourcePath) ||
                other.sourcePath == sourcePath));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode {
    return Object.hash(
      runtimeType,
      index,
      name,
      text,
      html,
      css,
      charCount,
      const DeepCollectionEquality().hash(_segments),
      const DeepCollectionEquality().hash(_footnotes),
      const DeepCollectionEquality().hash(_anchors),
      sourcePath,
    );
  }

  @override
  String toString() {
    return 'FulltextChapter(index: $index, name: $name, text: $text, html: $html, css: $css, charCount: $charCount, segments: $segments, footnotes: $footnotes, anchors: $anchors, sourcePath: $sourcePath)';
  }
}

/// @nodoc
abstract mixin class _$FulltextChapterCopyWith<$Res>
    implements $FulltextChapterCopyWith<$Res> {
  factory _$FulltextChapterCopyWith(
    _FulltextChapter value,
    $Res Function(_FulltextChapter) _then,
  ) = __$FulltextChapterCopyWithImpl;
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
    List<FulltextFootnote>? footnotes,
    Map<String, int>? anchors,
    String? sourcePath,
  });
}

/// @nodoc
class __$FulltextChapterCopyWithImpl<$Res>
    implements _$FulltextChapterCopyWith<$Res> {
  __$FulltextChapterCopyWithImpl(this._self, this._then);

  final _FulltextChapter _self;
  final $Res Function(_FulltextChapter) _then;

  /// Create a copy of FulltextChapter
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? index = null,
    Object? name = freezed,
    Object? text = null,
    Object? html = freezed,
    Object? css = freezed,
    Object? charCount = freezed,
    Object? segments = freezed,
    Object? footnotes = freezed,
    Object? anchors = freezed,
    Object? sourcePath = freezed,
  }) {
    return _then(
      _FulltextChapter(
        index: null == index
            ? _self.index
            : index // ignore: cast_nullable_to_non_nullable
                  as int,
        name: freezed == name
            ? _self.name
            : name // ignore: cast_nullable_to_non_nullable
                  as String?,
        text: null == text
            ? _self.text
            : text // ignore: cast_nullable_to_non_nullable
                  as String,
        html: freezed == html
            ? _self.html
            : html // ignore: cast_nullable_to_non_nullable
                  as String?,
        css: freezed == css
            ? _self.css
            : css // ignore: cast_nullable_to_non_nullable
                  as String?,
        charCount: freezed == charCount
            ? _self.charCount
            : charCount // ignore: cast_nullable_to_non_nullable
                  as int?,
        segments: freezed == segments
            ? _self._segments
            : segments // ignore: cast_nullable_to_non_nullable
                  as List<FulltextSegment>?,
        footnotes: freezed == footnotes
            ? _self._footnotes
            : footnotes // ignore: cast_nullable_to_non_nullable
                  as List<FulltextFootnote>?,
        anchors: freezed == anchors
            ? _self._anchors
            : anchors // ignore: cast_nullable_to_non_nullable
                  as Map<String, int>?,
        sourcePath: freezed == sourcePath
            ? _self.sourcePath
            : sourcePath // ignore: cast_nullable_to_non_nullable
                  as String?,
      ),
    );
  }
}

/// @nodoc
mixin _$FulltextTocEntry {
  String get title;
  int get level;
  int? get chapterIndex;

  /// The `#fragment` the entry points at inside its chapter's file, when it has one.
  String? get fragment;
  List<FulltextTocEntry> get children;

  /// Create a copy of FulltextTocEntry
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $FulltextTocEntryCopyWith<FulltextTocEntry> get copyWith =>
      _$FulltextTocEntryCopyWithImpl<FulltextTocEntry>(
        this as FulltextTocEntry,
        _$identity,
      );

  /// Serializes this FulltextTocEntry to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    final _this = this as FulltextTocEntry;
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is FulltextTocEntry &&
            (identical(other.title, _this.title) ||
                other.title == _this.title) &&
            (identical(other.level, _this.level) ||
                other.level == _this.level) &&
            (identical(other.chapterIndex, _this.chapterIndex) ||
                other.chapterIndex == _this.chapterIndex) &&
            (identical(other.fragment, _this.fragment) ||
                other.fragment == _this.fragment) &&
            const DeepCollectionEquality().equals(
              other.children,
              _this.children,
            ));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode {
    final _this = this as FulltextTocEntry;
    return Object.hash(
      runtimeType,
      _this.title,
      _this.level,
      _this.chapterIndex,
      _this.fragment,
      const DeepCollectionEquality().hash(_this.children),
    );
  }

  @override
  String toString() {
    final _this = this as FulltextTocEntry;
    return 'FulltextTocEntry(title: ${_this.title}, level: ${_this.level}, chapterIndex: ${_this.chapterIndex}, fragment: ${_this.fragment}, children: ${_this.children})';
  }
}

/// @nodoc
abstract mixin class $FulltextTocEntryCopyWith<$Res> {
  factory $FulltextTocEntryCopyWith(
    FulltextTocEntry value,
    $Res Function(FulltextTocEntry) _then,
  ) = _$FulltextTocEntryCopyWithImpl;
  @useResult
  $Res call({
    String title,
    int level,
    int? chapterIndex,
    String? fragment,
    List<FulltextTocEntry> children,
  });
}

/// @nodoc
class _$FulltextTocEntryCopyWithImpl<$Res>
    implements $FulltextTocEntryCopyWith<$Res> {
  _$FulltextTocEntryCopyWithImpl(this._self, this._then);

  final FulltextTocEntry _self;
  final $Res Function(FulltextTocEntry) _then;

  /// Create a copy of FulltextTocEntry
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? title = null,
    Object? level = null,
    Object? chapterIndex = freezed,
    Object? fragment = freezed,
    Object? children = null,
  }) {
    return _then(
      FulltextTocEntry(
        title: null == title
            ? _self.title
            : title // ignore: cast_nullable_to_non_nullable
                  as String,
        level: null == level
            ? _self.level
            : level // ignore: cast_nullable_to_non_nullable
                  as int,
        chapterIndex: freezed == chapterIndex
            ? _self.chapterIndex
            : chapterIndex // ignore: cast_nullable_to_non_nullable
                  as int?,
        fragment: freezed == fragment
            ? _self.fragment
            : fragment // ignore: cast_nullable_to_non_nullable
                  as String?,
        children: null == children
            ? _self.children
            : children // ignore: cast_nullable_to_non_nullable
                  as List<FulltextTocEntry>,
      ),
    );
  }
}

/// Adds pattern-matching-related methods to [FulltextTocEntry].
extension FulltextTocEntryPatterns on FulltextTocEntry {
  /// A variant of `map` that fallback to returning `orElse`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>(
    TResult Function(_FulltextTocEntry value)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _FulltextTocEntry() when $default != null:
        return $default(_that);
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// Callbacks receives the raw object, upcasted.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case final Subclass2 value:
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult map<TResult extends Object?>(
    TResult Function(_FulltextTocEntry value) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _FulltextTocEntry():
        return $default(_that);
      case _:
        throw StateError('Unexpected subclass');
    }
  }

  /// A variant of `map` that fallback to returning `null`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>(
    TResult? Function(_FulltextTocEntry value)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _FulltextTocEntry() when $default != null:
        return $default(_that);
      case _:
        return null;
    }
  }

  /// A variant of `when` that fallback to an `orElse` callback.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>(
    TResult Function(
      String title,
      int level,
      int? chapterIndex,
      String? fragment,
      List<FulltextTocEntry> children,
    )?
    $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _FulltextTocEntry() when $default != null:
        return $default(
          _that.title,
          _that.level,
          _that.chapterIndex,
          _that.fragment,
          _that.children,
        );
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// As opposed to `map`, this offers destructuring.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case Subclass2(:final field2):
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult when<TResult extends Object?>(
    TResult Function(
      String title,
      int level,
      int? chapterIndex,
      String? fragment,
      List<FulltextTocEntry> children,
    )
    $default,
  ) {
    final _that = this;
    switch (_that) {
      case _FulltextTocEntry():
        return $default(
          _that.title,
          _that.level,
          _that.chapterIndex,
          _that.fragment,
          _that.children,
        );
      case _:
        throw StateError('Unexpected subclass');
    }
  }

  /// A variant of `when` that fallback to returning `null`
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>(
    TResult? Function(
      String title,
      int level,
      int? chapterIndex,
      String? fragment,
      List<FulltextTocEntry> children,
    )?
    $default,
  ) {
    final _that = this;
    switch (_that) {
      case _FulltextTocEntry() when $default != null:
        return $default(
          _that.title,
          _that.level,
          _that.chapterIndex,
          _that.fragment,
          _that.children,
        );
      case _:
        return null;
    }
  }
}

/// @nodoc
@JsonSerializable()
class _FulltextTocEntry implements FulltextTocEntry {
  const _FulltextTocEntry({
    required this.title,
    this.level = 1,
    this.chapterIndex,
    this.fragment,
    List<FulltextTocEntry> children = const <FulltextTocEntry>[],
  }) : _children = children;
  factory _FulltextTocEntry.fromJson(Map<String, dynamic> json) =>
      _$FulltextTocEntryFromJson(json);

  @override
  final String title;
  @override
  @JsonKey()
  final int level;
  @override
  final int? chapterIndex;

  /// The `#fragment` the entry points at inside its chapter's file, when it has one.
  @override
  final String? fragment;
  final List<FulltextTocEntry> _children;
  @override
  @JsonKey()
  List<FulltextTocEntry> get children {
    if (_children is EqualUnmodifiableListView) return _children;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_children);
  }

  /// Create a copy of FulltextTocEntry
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$FulltextTocEntryCopyWith<_FulltextTocEntry> get copyWith =>
      __$FulltextTocEntryCopyWithImpl<_FulltextTocEntry>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$FulltextTocEntryToJson(this);
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _FulltextTocEntry &&
            (identical(other.title, title) || other.title == title) &&
            (identical(other.level, level) || other.level == level) &&
            (identical(other.chapterIndex, chapterIndex) ||
                other.chapterIndex == chapterIndex) &&
            (identical(other.fragment, fragment) ||
                other.fragment == fragment) &&
            const DeepCollectionEquality().equals(other.children, _children));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode {
    return Object.hash(
      runtimeType,
      title,
      level,
      chapterIndex,
      fragment,
      const DeepCollectionEquality().hash(_children),
    );
  }

  @override
  String toString() {
    return 'FulltextTocEntry(title: $title, level: $level, chapterIndex: $chapterIndex, fragment: $fragment, children: $children)';
  }
}

/// @nodoc
abstract mixin class _$FulltextTocEntryCopyWith<$Res>
    implements $FulltextTocEntryCopyWith<$Res> {
  factory _$FulltextTocEntryCopyWith(
    _FulltextTocEntry value,
    $Res Function(_FulltextTocEntry) _then,
  ) = __$FulltextTocEntryCopyWithImpl;
  @override
  @useResult
  $Res call({
    String title,
    int level,
    int? chapterIndex,
    String? fragment,
    List<FulltextTocEntry> children,
  });
}

/// @nodoc
class __$FulltextTocEntryCopyWithImpl<$Res>
    implements _$FulltextTocEntryCopyWith<$Res> {
  __$FulltextTocEntryCopyWithImpl(this._self, this._then);

  final _FulltextTocEntry _self;
  final $Res Function(_FulltextTocEntry) _then;

  /// Create a copy of FulltextTocEntry
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? title = null,
    Object? level = null,
    Object? chapterIndex = freezed,
    Object? fragment = freezed,
    Object? children = null,
  }) {
    return _then(
      _FulltextTocEntry(
        title: null == title
            ? _self.title
            : title // ignore: cast_nullable_to_non_nullable
                  as String,
        level: null == level
            ? _self.level
            : level // ignore: cast_nullable_to_non_nullable
                  as int,
        chapterIndex: freezed == chapterIndex
            ? _self.chapterIndex
            : chapterIndex // ignore: cast_nullable_to_non_nullable
                  as int?,
        fragment: freezed == fragment
            ? _self.fragment
            : fragment // ignore: cast_nullable_to_non_nullable
                  as String?,
        children: null == children
            ? _self._children
            : children // ignore: cast_nullable_to_non_nullable
                  as List<FulltextTocEntry>,
      ),
    );
  }
}

/// @nodoc
mixin _$EbookFulltext {
  String get jobId;
  String? get bookTitle;
  String? get bookAuthor;
  List<FulltextChapter> get chapters;

  /// The book's own contents list (nav/NCX); empty when the book has none.
  List<FulltextTocEntry> get toc;

  /// PDF pages without selectable text that the shared parser left out; 0 for EPUBs.
  @JsonKey(name: 'skipped_pages')
  int get skippedPages;

  /// Create a copy of EbookFulltext
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $EbookFulltextCopyWith<EbookFulltext> get copyWith =>
      _$EbookFulltextCopyWithImpl<EbookFulltext>(
        this as EbookFulltext,
        _$identity,
      );

  /// Serializes this EbookFulltext to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    final _this = this as EbookFulltext;
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is EbookFulltext &&
            (identical(other.jobId, _this.jobId) ||
                other.jobId == _this.jobId) &&
            (identical(other.bookTitle, _this.bookTitle) ||
                other.bookTitle == _this.bookTitle) &&
            (identical(other.bookAuthor, _this.bookAuthor) ||
                other.bookAuthor == _this.bookAuthor) &&
            const DeepCollectionEquality().equals(
              other.chapters,
              _this.chapters,
            ) &&
            const DeepCollectionEquality().equals(other.toc, _this.toc) &&
            (identical(other.skippedPages, _this.skippedPages) ||
                other.skippedPages == _this.skippedPages));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode {
    final _this = this as EbookFulltext;
    return Object.hash(
      runtimeType,
      _this.jobId,
      _this.bookTitle,
      _this.bookAuthor,
      const DeepCollectionEquality().hash(_this.chapters),
      const DeepCollectionEquality().hash(_this.toc),
      _this.skippedPages,
    );
  }

  @override
  String toString() {
    final _this = this as EbookFulltext;
    return 'EbookFulltext(jobId: ${_this.jobId}, bookTitle: ${_this.bookTitle}, bookAuthor: ${_this.bookAuthor}, chapters: ${_this.chapters}, toc: ${_this.toc}, skippedPages: ${_this.skippedPages})';
  }
}

/// @nodoc
abstract mixin class $EbookFulltextCopyWith<$Res> {
  factory $EbookFulltextCopyWith(
    EbookFulltext value,
    $Res Function(EbookFulltext) _then,
  ) = _$EbookFulltextCopyWithImpl;
  @useResult
  $Res call({
    String jobId,
    String? bookTitle,
    String? bookAuthor,
    List<FulltextChapter> chapters,
    List<FulltextTocEntry> toc,
    @JsonKey(name: 'skipped_pages') int skippedPages,
  });
}

/// @nodoc
class _$EbookFulltextCopyWithImpl<$Res>
    implements $EbookFulltextCopyWith<$Res> {
  _$EbookFulltextCopyWithImpl(this._self, this._then);

  final EbookFulltext _self;
  final $Res Function(EbookFulltext) _then;

  /// Create a copy of EbookFulltext
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? jobId = null,
    Object? bookTitle = freezed,
    Object? bookAuthor = freezed,
    Object? chapters = null,
    Object? toc = null,
    Object? skippedPages = null,
  }) {
    return _then(
      EbookFulltext(
        jobId: null == jobId
            ? _self.jobId
            : jobId // ignore: cast_nullable_to_non_nullable
                  as String,
        bookTitle: freezed == bookTitle
            ? _self.bookTitle
            : bookTitle // ignore: cast_nullable_to_non_nullable
                  as String?,
        bookAuthor: freezed == bookAuthor
            ? _self.bookAuthor
            : bookAuthor // ignore: cast_nullable_to_non_nullable
                  as String?,
        chapters: null == chapters
            ? _self.chapters
            : chapters // ignore: cast_nullable_to_non_nullable
                  as List<FulltextChapter>,
        toc: null == toc
            ? _self.toc
            : toc // ignore: cast_nullable_to_non_nullable
                  as List<FulltextTocEntry>,
        skippedPages: null == skippedPages
            ? _self.skippedPages
            : skippedPages // ignore: cast_nullable_to_non_nullable
                  as int,
      ),
    );
  }
}

/// Adds pattern-matching-related methods to [EbookFulltext].
extension EbookFulltextPatterns on EbookFulltext {
  /// A variant of `map` that fallback to returning `orElse`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>(
    TResult Function(_EbookFulltext value)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _EbookFulltext() when $default != null:
        return $default(_that);
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// Callbacks receives the raw object, upcasted.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case final Subclass2 value:
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult map<TResult extends Object?>(
    TResult Function(_EbookFulltext value) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _EbookFulltext():
        return $default(_that);
      case _:
        throw StateError('Unexpected subclass');
    }
  }

  /// A variant of `map` that fallback to returning `null`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>(
    TResult? Function(_EbookFulltext value)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _EbookFulltext() when $default != null:
        return $default(_that);
      case _:
        return null;
    }
  }

  /// A variant of `when` that fallback to an `orElse` callback.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>(
    TResult Function(
      String jobId,
      String? bookTitle,
      String? bookAuthor,
      List<FulltextChapter> chapters,
      List<FulltextTocEntry> toc,
      @JsonKey(name: 'skipped_pages') int skippedPages,
    )?
    $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _EbookFulltext() when $default != null:
        return $default(
          _that.jobId,
          _that.bookTitle,
          _that.bookAuthor,
          _that.chapters,
          _that.toc,
          _that.skippedPages,
        );
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// As opposed to `map`, this offers destructuring.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case Subclass2(:final field2):
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult when<TResult extends Object?>(
    TResult Function(
      String jobId,
      String? bookTitle,
      String? bookAuthor,
      List<FulltextChapter> chapters,
      List<FulltextTocEntry> toc,
      @JsonKey(name: 'skipped_pages') int skippedPages,
    )
    $default,
  ) {
    final _that = this;
    switch (_that) {
      case _EbookFulltext():
        return $default(
          _that.jobId,
          _that.bookTitle,
          _that.bookAuthor,
          _that.chapters,
          _that.toc,
          _that.skippedPages,
        );
      case _:
        throw StateError('Unexpected subclass');
    }
  }

  /// A variant of `when` that fallback to returning `null`
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>(
    TResult? Function(
      String jobId,
      String? bookTitle,
      String? bookAuthor,
      List<FulltextChapter> chapters,
      List<FulltextTocEntry> toc,
      @JsonKey(name: 'skipped_pages') int skippedPages,
    )?
    $default,
  ) {
    final _that = this;
    switch (_that) {
      case _EbookFulltext() when $default != null:
        return $default(
          _that.jobId,
          _that.bookTitle,
          _that.bookAuthor,
          _that.chapters,
          _that.toc,
          _that.skippedPages,
        );
      case _:
        return null;
    }
  }
}

/// @nodoc
@JsonSerializable()
class _EbookFulltext implements EbookFulltext {
  const _EbookFulltext({
    required this.jobId,
    this.bookTitle,
    this.bookAuthor,
    required List<FulltextChapter> chapters,
    List<FulltextTocEntry> toc = const <FulltextTocEntry>[],
    @JsonKey(name: 'skipped_pages') this.skippedPages = 0,
  }) : _chapters = chapters,
       _toc = toc;
  factory _EbookFulltext.fromJson(Map<String, dynamic> json) =>
      _$EbookFulltextFromJson(json);

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

  /// The book's own contents list (nav/NCX); empty when the book has none.
  final List<FulltextTocEntry> _toc;

  /// The book's own contents list (nav/NCX); empty when the book has none.
  @override
  @JsonKey()
  List<FulltextTocEntry> get toc {
    if (_toc is EqualUnmodifiableListView) return _toc;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_toc);
  }

  /// PDF pages without selectable text that the shared parser left out; 0 for EPUBs.
  @override
  @JsonKey(name: 'skipped_pages')
  final int skippedPages;

  /// Create a copy of EbookFulltext
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$EbookFulltextCopyWith<_EbookFulltext> get copyWith =>
      __$EbookFulltextCopyWithImpl<_EbookFulltext>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$EbookFulltextToJson(this);
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _EbookFulltext &&
            (identical(other.jobId, jobId) || other.jobId == jobId) &&
            (identical(other.bookTitle, bookTitle) ||
                other.bookTitle == bookTitle) &&
            (identical(other.bookAuthor, bookAuthor) ||
                other.bookAuthor == bookAuthor) &&
            const DeepCollectionEquality().equals(other.chapters, _chapters) &&
            const DeepCollectionEquality().equals(other.toc, _toc) &&
            (identical(other.skippedPages, skippedPages) ||
                other.skippedPages == skippedPages));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode {
    return Object.hash(
      runtimeType,
      jobId,
      bookTitle,
      bookAuthor,
      const DeepCollectionEquality().hash(_chapters),
      const DeepCollectionEquality().hash(_toc),
      skippedPages,
    );
  }

  @override
  String toString() {
    return 'EbookFulltext(jobId: $jobId, bookTitle: $bookTitle, bookAuthor: $bookAuthor, chapters: $chapters, toc: $toc, skippedPages: $skippedPages)';
  }
}

/// @nodoc
abstract mixin class _$EbookFulltextCopyWith<$Res>
    implements $EbookFulltextCopyWith<$Res> {
  factory _$EbookFulltextCopyWith(
    _EbookFulltext value,
    $Res Function(_EbookFulltext) _then,
  ) = __$EbookFulltextCopyWithImpl;
  @override
  @useResult
  $Res call({
    String jobId,
    String? bookTitle,
    String? bookAuthor,
    List<FulltextChapter> chapters,
    List<FulltextTocEntry> toc,
    @JsonKey(name: 'skipped_pages') int skippedPages,
  });
}

/// @nodoc
class __$EbookFulltextCopyWithImpl<$Res>
    implements _$EbookFulltextCopyWith<$Res> {
  __$EbookFulltextCopyWithImpl(this._self, this._then);

  final _EbookFulltext _self;
  final $Res Function(_EbookFulltext) _then;

  /// Create a copy of EbookFulltext
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? jobId = null,
    Object? bookTitle = freezed,
    Object? bookAuthor = freezed,
    Object? chapters = null,
    Object? toc = null,
    Object? skippedPages = null,
  }) {
    return _then(
      _EbookFulltext(
        jobId: null == jobId
            ? _self.jobId
            : jobId // ignore: cast_nullable_to_non_nullable
                  as String,
        bookTitle: freezed == bookTitle
            ? _self.bookTitle
            : bookTitle // ignore: cast_nullable_to_non_nullable
                  as String?,
        bookAuthor: freezed == bookAuthor
            ? _self.bookAuthor
            : bookAuthor // ignore: cast_nullable_to_non_nullable
                  as String?,
        chapters: null == chapters
            ? _self._chapters
            : chapters // ignore: cast_nullable_to_non_nullable
                  as List<FulltextChapter>,
        toc: null == toc
            ? _self._toc
            : toc // ignore: cast_nullable_to_non_nullable
                  as List<FulltextTocEntry>,
        skippedPages: null == skippedPages
            ? _self.skippedPages
            : skippedPages // ignore: cast_nullable_to_non_nullable
                  as int,
      ),
    );
  }
}
