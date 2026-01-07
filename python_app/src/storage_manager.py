# -*- coding: utf-8 -*-
"""Storage manager for uploading files to Cloudflare R2 (S3-compatible)."""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from typing import List, Optional

logger = logging.getLogger(__name__)


@dataclass
class UploadResult:
    """Result of file upload to R2."""

    success: bool
    public_url: Optional[str] = None
    object_key: Optional[str] = None
    error: Optional[str] = None
    size_bytes: int = 0


class R2StorageManager:
    """Manage file uploads to Cloudflare R2 (S3-compatible storage)."""

    def __init__(
        self,
        account_id: Optional[str] = None,
        access_key_id: Optional[str] = None,
        secret_access_key: Optional[str] = None,
        bucket_name: Optional[str] = None,
        public_url_base: Optional[str] = None,
    ):
        """
        Initialize R2 storage manager.

        Args:
            account_id: Cloudflare account ID
            access_key_id: R2 access key ID
            secret_access_key: R2 secret access key
            bucket_name: R2 bucket name
            public_url_base: Base URL for public access (e.g., https://pub-xxxxx.r2.dev)
        """
        self.account_id = account_id or os.getenv("R2_ACCOUNT_ID")
        self.access_key_id = access_key_id or os.getenv("R2_ACCESS_KEY_ID")
        self.secret_access_key = secret_access_key or os.getenv("R2_SECRET_ACCESS_KEY")
        self.bucket_name = bucket_name or os.getenv("R2_BUCKET_NAME", "epub-to-mp3")
        self.public_url_base = public_url_base or os.getenv("R2_PUBLIC_URL")

        self._s3_client = None
        self._enabled = self._check_enabled()

    def _check_enabled(self) -> bool:
        """Check if R2 is properly configured."""
        optional = os.getenv("R2_OPTIONAL", "true").strip().lower() in {
            "1",
            "true",
            "yes",
            "on",
        }
        if not all([self.account_id, self.access_key_id, self.secret_access_key]):
            message = "R2 not configured - missing credentials. Files will be stored locally only."
            if optional:
                logger.info(message)
            else:
                logger.warning(message)
            return False
        return True

    def is_enabled(self) -> bool:
        """Check if R2 storage is enabled and configured."""
        return self._enabled

    def _get_s3_client(self):
        """Get or create boto3 S3 client for R2."""
        if self._s3_client is not None:
            return self._s3_client

        try:
            import boto3
        except ImportError:
            logger.error("boto3 not installed. Install with: pip install boto3")
            self._enabled = False
            return None

        endpoint_url = f"https://{self.account_id}.r2.cloudflarestorage.com"

        self._s3_client = boto3.client(
            "s3",
            endpoint_url=endpoint_url,
            aws_access_key_id=self.access_key_id,
            aws_secret_access_key=self.secret_access_key,
            region_name="auto",  # R2 uses "auto" region
        )

        logger.info(f"R2 client initialized: {endpoint_url}")
        return self._s3_client

    def upload_file(
        self,
        file_path: Path,
        object_key: Optional[str] = None,
        ttl_hours: int = 48,
        content_type: Optional[str] = None,
    ) -> UploadResult:
        """
        Upload file to R2 bucket.

        Args:
            file_path: Path to file to upload
            object_key: Key (path) in bucket. If None, uses filename with timestamp prefix
            ttl_hours: Time to live in hours (for cleanup purposes)
            content_type: MIME type (auto-detected if None)

        Returns:
            UploadResult with success status and public URL
        """
        if not self.is_enabled():
            return UploadResult(success=False, error="R2 storage not configured")

        if not file_path.exists():
            return UploadResult(success=False, error=f"File not found: {file_path}")

        client = self._get_s3_client()
        if client is None:
            return UploadResult(success=False, error="Failed to initialize R2 client")

        try:
            # Generate object key if not provided
            if object_key is None:
                timestamp = datetime.utcnow().strftime("%Y%m%d_%H%M%S")
                object_key = f"audiobooks/{timestamp}/{file_path.name}"

            # Detect content type
            if content_type is None:
                import mimetypes

                content_type, _ = mimetypes.guess_type(str(file_path))
                if content_type is None:
                    if file_path.suffix.lower() == ".mp3":
                        content_type = "audio/mpeg"
                    elif file_path.suffix.lower() == ".zip":
                        content_type = "application/zip"
                    else:
                        content_type = "application/octet-stream"

            # Upload file
            file_size = file_path.stat().st_size
            expiry = datetime.utcnow() + timedelta(hours=ttl_hours)

            extra_args = {
                "ContentType": content_type,
                "Metadata": {
                    "ttl-hours": str(ttl_hours),
                    "expires-at": expiry.isoformat(),
                },
            }

            logger.info(f"Uploading {file_path.name} ({file_size / 1024 / 1024:.2f} MB) to R2...")

            with open(file_path, "rb") as f:
                client.put_object(Bucket=self.bucket_name, Key=object_key, Body=f, **extra_args)

            # Generate public URL
            if self.public_url_base:
                public_url = f"{self.public_url_base}/{object_key}"
            else:
                # Fallback: generate presigned URL (expires in 24h)
                public_url = client.generate_presigned_url(
                    "get_object",
                    Params={"Bucket": self.bucket_name, "Key": object_key},
                    ExpiresIn=86400,  # 24 hours
                )

            logger.info(f"✅ Uploaded to R2: {object_key}")

            return UploadResult(
                success=True, public_url=public_url, object_key=object_key, size_bytes=file_size
            )

        except Exception as e:
            logger.error(f"Failed to upload {file_path} to R2: {e}", exc_info=True)
            return UploadResult(success=False, error=str(e))

    def delete_file(self, object_key: str) -> bool:
        """Delete file from R2 bucket."""
        if not self.is_enabled():
            return False

        client = self._get_s3_client()
        if client is None:
            return False

        try:
            client.delete_object(Bucket=self.bucket_name, Key=object_key)
            logger.info(f"Deleted from R2: {object_key}")
            return True
        except Exception as e:
            logger.error(f"Failed to delete {object_key} from R2: {e}")
            return False

    def cleanup_old_files(self, max_age_hours: int = 48) -> int:
        """
        Cleanup files older than max_age_hours.

        Returns:
            Number of files deleted
        """
        if not self.is_enabled():
            return 0

        client = self._get_s3_client()
        if client is None:
            return 0

        try:
            cutoff_time = datetime.utcnow() - timedelta(hours=max_age_hours)
            deleted_count = 0

            # List all objects in bucket
            paginator = client.get_paginator("list_objects_v2")
            pages = paginator.paginate(Bucket=self.bucket_name)

            for page in pages:
                if "Contents" not in page:
                    continue

                for obj in page["Contents"]:
                    # Check last modified time
                    if obj["LastModified"].replace(tzinfo=None) < cutoff_time:
                        self.delete_file(obj["Key"])
                        deleted_count += 1

            logger.info(f"R2 cleanup: deleted {deleted_count} files older than {max_age_hours}h")
            return deleted_count

        except Exception as e:
            logger.error(f"Failed to cleanup R2 bucket: {e}")
            return 0

    def list_files(self, prefix: str = "") -> List[dict]:
        """List files in R2 bucket with optional prefix filter."""
        if not self.is_enabled():
            return []

        client = self._get_s3_client()
        if client is None:
            return []

        try:
            response = client.list_objects_v2(Bucket=self.bucket_name, Prefix=prefix)

            files = []
            if "Contents" in response:
                for obj in response["Contents"]:
                    files.append(
                        {
                            "key": obj["Key"],
                            "size": obj["Size"],
                            "last_modified": obj["LastModified"],
                        }
                    )

            return files

        except Exception as e:
            logger.error(f"Failed to list R2 files: {e}")
            return []


# Global instance (singleton)
_storage_manager = None


def get_storage_manager() -> R2StorageManager:
    """Get global R2 storage manager instance."""
    global _storage_manager
    if _storage_manager is None:
        _storage_manager = R2StorageManager()
    return _storage_manager
