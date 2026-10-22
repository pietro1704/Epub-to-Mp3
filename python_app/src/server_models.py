# -*- coding: utf-8 -*-
"""Pydantic request and response identities for the legacy HTTP server."""

from typing import Optional

from pydantic import BaseModel


class JobStatus(BaseModel):
    jobId: str
    state: str
    events: list[str] = []
    rawLog: list[str] = []
    detectedLanguage: Optional[str] = None
    chaptersTotal: Optional[int] = None
    chaptersCompleted: Optional[int] = None
    currentChapter: Optional[str] = None
    progressPercent: Optional[float] = None
    chapterProgress: Optional[list[dict]] = None
    totalSegments: Optional[int] = None
    completedSegments: Optional[int] = None
    outputs: list[dict] = []
    error: Optional[str] = None
    bookTitle: Optional[str] = None
    bookAuthor: Optional[str] = None
    coverUrl: Optional[str] = None
    coverMimeType: Optional[str] = None
    logUrl: Optional[str] = None
    parallelSlots: Optional[int] = None
    parallelActive: Optional[int] = None
    statusHint: Optional[str] = None
    engine: Optional[str] = None
    voice: Optional[str] = None
    language: Optional[str] = None
    formattingCues: Optional[bool] = None
    uiLanguage: Optional[str] = None
    lastActivityAt: Optional[float] = None
    noParallel: Optional[bool] = None
    journeyObservations: list[dict] = []


class JourneyObservationInput(BaseModel):
    """A privacy-safe client timing record for one conversion journey."""

    journeyId: str
    transition: str
    elapsedNanoseconds: int


class RestartOptions(BaseModel):
    keep_cache: bool = False
    keep_finished: bool = False
