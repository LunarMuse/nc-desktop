/*
 * Copyright (C) 2023 by Claudio Cambra <claudio.cambra@nextcloud.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
 * or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
 * for more details.
 */

#include "fileprovideritemmetadata.h"

#include <QLoggingCategory>

#import <Foundation/Foundation.h>
#import <FileProvider/FileProvider.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

namespace {

QString nsNameComponentsToLocalisedQString(NSPersonNameComponents *const nameComponents)
{
    if (nameComponents == nil) {
        return {};
    }

    NSString *const name = [NSPersonNameComponentsFormatter localizedStringFromPersonNameComponents:nameComponents style:NSPersonNameComponentsFormatterStyleDefault options:0];
    return QString::fromNSString(name);
}

QHash<QString, QByteArray> extendedAttributesToHash(NSDictionary<NSString *, NSData *> *const extendedAttributes)
{
    QHash<QString, QByteArray> hash;
    for (NSString *const key in extendedAttributes) {
        NSData *const value = [extendedAttributes objectForKey:key];
        hash.insert(QString::fromNSString(key), QByteArray::fromNSData(value));
    }
    return hash;
}

}

namespace OCC {

namespace Mac {

Q_LOGGING_CATEGORY(lcMacImplFileProviderItemMetadata, "nextcloud.gui.macfileprovideritemmetadatamacimpl", QtInfoMsg)

FileProviderItemMetadata FileProviderItemMetadata::fromNSFileProviderItem(const void *const nsFileProviderItem, const QString &domainIdentifier)
{
    FileProviderItemMetadata metadata;
    const id<NSFileProviderItem> bridgedNsFileProviderItem = (__bridge id<NSFileProviderItem>)nsFileProviderItem;
    if (bridgedNsFileProviderItem == nil) {
        return {};
    }

    metadata._identifier = QString::fromNSString(bridgedNsFileProviderItem.itemIdentifier);
    metadata._parentItemIdentifier = QString::fromNSString(bridgedNsFileProviderItem.parentItemIdentifier);
    metadata._domainIdentifier = domainIdentifier;
    metadata._filename = QString::fromNSString(bridgedNsFileProviderItem.filename);
    metadata._typeIdentifier = QString::fromNSString(bridgedNsFileProviderItem.contentType.identifier);
    metadata._symlinkTargetPath = QString::fromNSString(bridgedNsFileProviderItem.symlinkTargetPath);
    metadata._uploadingError = QString::fromNSString(bridgedNsFileProviderItem.uploadingError.localizedDescription);
    metadata._downloadingError = QString::fromNSString(bridgedNsFileProviderItem.downloadingError.localizedDescription);
    metadata._mostRecentEditorName = nsNameComponentsToLocalisedQString(bridgedNsFileProviderItem.mostRecentEditorNameComponents);
    metadata._ownerName = nsNameComponentsToLocalisedQString(bridgedNsFileProviderItem.ownerNameComponents);
    metadata._contentModificationDate = QDateTime::fromNSDate(bridgedNsFileProviderItem.contentModificationDate);
    metadata._creationDate = QDateTime::fromNSDate(bridgedNsFileProviderItem.creationDate);
    metadata._lastUsedDate = QDateTime::fromNSDate(bridgedNsFileProviderItem.lastUsedDate);
    metadata._contentVersion = QByteArray::fromNSData(bridgedNsFileProviderItem.itemVersion.contentVersion);
    metadata._metadataVersion = QByteArray::fromNSData(bridgedNsFileProviderItem.itemVersion.metadataVersion);
    metadata._tagData = QByteArray::fromNSData(bridgedNsFileProviderItem.tagData);
    metadata._extendedAttributes = extendedAttributesToHash(bridgedNsFileProviderItem.extendedAttributes);
    metadata._capabilities = bridgedNsFileProviderItem.capabilities;
    metadata._fileSystemFlags = bridgedNsFileProviderItem.fileSystemFlags;
    metadata._childItemCount = bridgedNsFileProviderItem.childItemCount.unsignedIntegerValue;
    metadata._typeOsCode = bridgedNsFileProviderItem.typeAndCreator.type;
    metadata._creatorOsCode = bridgedNsFileProviderItem.typeAndCreator.creator;
    metadata._documentSize = bridgedNsFileProviderItem.documentSize.unsignedLongLongValue;
    metadata._mostRecentVersionDownloaded = bridgedNsFileProviderItem.mostRecentVersionDownloaded;
    metadata._uploading = bridgedNsFileProviderItem.uploading;
    metadata._uploaded = bridgedNsFileProviderItem.uploaded;
    metadata._downloading = bridgedNsFileProviderItem.downloading;
    metadata._downloaded = bridgedNsFileProviderItem.downloaded;
    metadata._shared = bridgedNsFileProviderItem.shared;
    metadata._sharedByCurrentUser = bridgedNsFileProviderItem.sharedByCurrentUser;

    metadata._userVisiblePath = metadata.getUserVisiblePath();
    metadata._fileTypeString = QString::fromNSString(bridgedNsFileProviderItem.contentType.localizedDescription);

    return metadata;
}

QString FileProviderItemMetadata::getUserVisiblePath() const
{
    qCDebug(lcMacImplFileProviderItemMetadata) << "Getting user visible path";

    const auto id = identifier();
    const auto domainId = domainIdentifier();

    if (id.isEmpty() || domainId.isEmpty()) {
        qCWarning(lcMacImplFileProviderItemMetadata) << "Could not fetch user visible path for item, no identifier or domainIdentifier";
        return QStringLiteral("Unknown");
    }

    NSString *const nsItemIdentifier = id.toNSString();
    NSString *const nsDomainIdentifier = domainId.toNSString();

    __block QString returnPath = QObject::tr("Unknown");
    __block NSFileProviderManager *manager = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    // getDomainsWithCompletionHandler is asynchronous -- we create a dispatch semaphore in order
    // to wait until it is done. This should tell you that we should not call this method very
    // often!

    [NSFileProviderManager getDomainsWithCompletionHandler:^(NSArray<NSFileProviderDomain *> *const domains, NSError *const error) {
        if (error != nil) {
            qCWarning(lcMacImplFileProviderItemMetadata) << "Error fetching domains:" << error.localizedDescription;
            dispatch_semaphore_signal(semaphore);
            return;
        }

        BOOL foundDomain = NO;

        for (NSFileProviderDomain *const domain in domains) {
            if ([domain.identifier isEqualToString:nsDomainIdentifier]) {
                 foundDomain = YES;
                 manager = [NSFileProviderManager managerForDomain:domain];
            }
        }

        if (!foundDomain) {
            qCWarning(lcMacImplFileProviderItemMetadata) << "No matching item domain, cannot get item path";
        }

        dispatch_semaphore_signal(semaphore);
    }];

    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

    if (manager == nil) {
        qCWarning(lcMacImplFileProviderItemMetadata) << "Null manager, cannot get item path";
        dispatch_release(semaphore);
        return returnPath;
    }

    // getUserVisibleUrl is also async, so wait here too

    [manager getUserVisibleURLForItemIdentifier:nsItemIdentifier
                              completionHandler:^(NSURL *const userVisibleFile, NSError *const error) {
        qCDebug(lcMacImplFileProviderItemMetadata) << "Got user visible url for item identifier." << "url:" << userVisibleFile << "error:" << error.localizedDescription;

        if (error != nil) {
            qCWarning(lcMacImplFileProviderItemMetadata) << "Error fetching user visible url for item identifier." << error.localizedDescription;
        } else {
            returnPath = QString::fromNSString(userVisibleFile.path);
        }

        dispatch_semaphore_signal(semaphore);
    }];

    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    dispatch_release(semaphore);

    return returnPath;
}

}

}
