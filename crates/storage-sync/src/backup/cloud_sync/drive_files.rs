//! Google Drive appDataFolder objects. Fixed API origins, explicit object IDs,
//! complete bounded discovery and fail-closed conditional publication. No
//! account lookup, timer, unsolicited creation, deletion or unconditional PUT.
use super::{
    MAX_ENCRYPTED_BYTES, PendingUpload, PublicationCondition, RemoteRead,
    drive_oauth::{self, AccessToken},
    opaque,
    webdav::{self, IndependentProxy, PutResponse, TransportError},
};
use reqwest::{Client, RequestBuilder, Response, StatusCode, Url, header};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use tokio_util::sync::CancellationToken;

const API: &str = "https://www.googleapis.com/drive/v3/files";
const UPLOAD: &str = "https://www.googleapis.com/upload/drive/v3/files";
const MIME: &str = "application/octet-stream";
const FIELDS: &str = "id,name,mimeType,size,spaces,trashed,appProperties";
const METADATA_LIMIT: usize = 256 * 1024;
const MAX_OBJECTS: usize = 512;
type HttpResult<T> = std::result::Result<T, TransportError>;

#[derive(Clone, Serialize)]
pub struct ConfigurationObject {
    pub id: String,
    pub collection: String,
    pub bytes: u64,
}

#[cfg(test)]
#[path = "drive_files_tests.rs"]
mod tests;
/// Not serializable and not constructible from a user-entered ID. A capability
/// returned only by generateIds(appDataFolder), consumed by explicit create.
/// An unknown create must be discovered/read before another publication.
pub struct ReservedObject {
    id: String,
}
impl ReservedObject {
    pub fn id(&self) -> &str {
        &self.id
    }
    /// Only the encrypted local creation journal may restore this capability.
    pub(super) fn restore(id: &str) -> HttpResult<Self> {
        if !valid_id(id) {
            return Err(TransportError::Configuration);
        }
        Ok(Self { id: id.into() })
    }
}

pub struct DriveFiles {
    client: Client,
    access: AccessToken,
    api: Url,
    upload: Url,
}
fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 256
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_'))
}
fn name(collection: &str) -> String {
    format!("hspterm-config-v1-{collection}.hspsync")
}
fn properties(collection: &str) -> BTreeMap<String, String> {
    BTreeMap::from([
        ("hsptermApplication".into(), "HSPTerm".into()),
        ("hsptermFormat".into(), "1".into()),
        ("hsptermCollection".into(), collection.into()),
    ])
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Metadata {
    id: String,
    name: String,
    mime_type: String,
    size: String,
    spaces: Vec<String>,
    trashed: bool,
    app_properties: BTreeMap<String, String>,
}
impl Metadata {
    fn checked(self) -> HttpResult<ConfigurationObject> {
        let collection = self
            .app_properties
            .get("hsptermCollection")
            .ok_or(TransportError::Response)?;
        if !valid_id(&self.id)
            || !opaque(collection)
            || self.mime_type != MIME
            || self.trashed
            || self.spaces.len() != 1
            || self.spaces[0] != "appDataFolder"
            || self.name != name(collection)
            || self.app_properties != properties(collection)
            || self.size.len() > 20
            || self.size.is_empty()
            || !self.size.bytes().all(|b| b.is_ascii_digit())
        {
            return Err(TransportError::Response);
        }
        let bytes = self
            .size
            .parse::<u64>()
            .map_err(|_| TransportError::Response)?;
        if bytes > MAX_ENCRYPTED_BYTES as u64 {
            return Err(TransportError::Capacity);
        }
        Ok(ConfigurationObject {
            id: self.id,
            collection: collection.clone(),
            bytes,
        })
    }
}
async fn json<T: for<'de> Deserialize<'de>>(response: &mut Response) -> HttpResult<T> {
    let raw = drive_oauth::bounded(response, METADATA_LIMIT)
        .await
        .map_err(|e| match e {
            drive_oauth::AuthorizationError::Network => TransportError::Network,
            _ => TransportError::Response,
        })?;
    serde_json::from_slice(&raw).map_err(|_| TransportError::Response)
}
fn read_status(response: &Response) -> HttpResult<()> {
    match response.status() {
        StatusCode::OK => Ok(()),
        StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => Err(TransportError::Denied),
        _ => Err(TransportError::Response),
    }
}
impl DriveFiles {
    pub fn object_endpoint(id: &str) -> HttpResult<String> {
        Ok(Self::object_url(
            &Url::parse(API).map_err(|_| TransportError::Configuration)?,
            id,
        )?
        .to_string())
    }
    pub fn new(
        access: AccessToken,
        proxy: Option<IndependentProxy>,
        timeout_seconds: u32,
    ) -> HttpResult<Self> {
        Ok(Self {
            client: webdav::client(proxy, timeout_seconds, false)?,
            access,
            api: Url::parse(API).map_err(|_| TransportError::Configuration)?,
            upload: Url::parse(UPLOAD).map_err(|_| TransportError::Configuration)?,
        })
    }
    fn request(&self, request: RequestBuilder) -> HttpResult<RequestBuilder> {
        if self
            .access
            .expires_within(std::time::Duration::from_secs(5))
        {
            return Err(TransportError::Denied);
        }
        Ok(self
            .access
            .authenticate(request)
            .header(header::ACCEPT_ENCODING, "identity")
            .header(header::CACHE_CONTROL, "no-store"))
    }
    fn object_url(base: &Url, id: &str) -> HttpResult<Url> {
        if !valid_id(id) {
            return Err(TransportError::Configuration);
        }
        let mut url = base.clone();
        url.path_segments_mut()
            .map_err(|_| TransportError::Configuration)?
            .push(id);
        Ok(url)
    }
    pub async fn discover(
        &self,
        cancel: &CancellationToken,
    ) -> HttpResult<Vec<ConfigurationObject>> {
        tokio::select! { biased;
            _ = cancel.cancelled() => Err(TransportError::Cancelled),
            result = self.discover_inner() => result,
        }
    }
    async fn discover_inner(&self) -> HttpResult<Vec<ConfigurationObject>> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase", deny_unknown_fields)]
        struct Page {
            files: Vec<Metadata>,
            next_page_token: Option<String>,
            incomplete_search: bool,
        }
        let mut page_token: Option<String> = None;
        let mut tokens = BTreeSet::new();
        let mut ids = BTreeSet::new();
        let mut objects = Vec::new();
        // Empty pages may still carry a continuation token. Never declare
        // complete until no token and incompleteSearch=false were observed.
        for _ in 0..32 {
            let mut url = self.api.clone();
            url.query_pairs_mut().append_pair("spaces", "appDataFolder")
                .append_pair("q", "trashed = false and appProperties has { key='hsptermApplication' and value='HSPTerm' }")
                .append_pair("pageSize", "100")
                .append_pair("fields", &format!("files({FIELDS}),nextPageToken,incompleteSearch"));
            if let Some(token) = &page_token {
                url.query_pairs_mut().append_pair("pageToken", token);
            }
            let mut response = self
                .request(self.client.get(url))?
                .send()
                .await
                .map_err(|_| TransportError::Network)?;
            read_status(&response)?;
            let page: Page = json(&mut response).await?;
            if page.incomplete_search || page.files.len() > 100 {
                return Err(TransportError::Response);
            }
            for file in page.files {
                let file = file.checked()?;
                if !ids.insert(file.id.clone()) {
                    return Err(TransportError::Response);
                }
                if objects.len() >= MAX_OBJECTS {
                    return Err(TransportError::Capacity);
                }
                // A collection may have multiple distinct file IDs. Keep ALL
                // candidates for explicit selection, never silently pick one.
                objects.push(file);
            }
            match page.next_page_token {
                None => {
                    objects.sort_by(|a, b| (&a.collection, &a.id).cmp(&(&b.collection, &b.id)));
                    return Ok(objects);
                }
                Some(token) => {
                    if token.is_empty()
                        || token.len() > 8192
                        || token.chars().any(char::is_control)
                        || !tokens.insert(token.clone())
                    {
                        return Err(TransportError::Response);
                    }
                    page_token = Some(token);
                }
            }
        }
        Err(TransportError::Capacity)
    }
    pub async fn reserve_object(&self, cancel: &CancellationToken) -> HttpResult<ReservedObject> {
        tokio::select! { biased;
            _ = cancel.cancelled() => Err(TransportError::Cancelled),
            result = self.reserve_inner() => result,
        }
    }
    async fn reserve_inner(&self) -> HttpResult<ReservedObject> {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Ids {
            ids: Vec<String>,
            space: String,
        }
        let mut url = Self::object_url(&self.api, "generateIds")?;
        url.query_pairs_mut()
            .append_pair("space", "appDataFolder")
            .append_pair("count", "1")
            .append_pair("type", "files")
            .append_pair("fields", "ids,space");
        let mut response = self
            .request(self.client.get(url))?
            .send()
            .await
            .map_err(|_| TransportError::Network)?;
        read_status(&response)?;
        let mut ids: Ids = json(&mut response).await?;
        if ids.space != "appDataFolder" || ids.ids.len() != 1 || !valid_id(&ids.ids[0]) {
            return Err(TransportError::Response);
        }
        Ok(ReservedObject {
            id: ids.ids.remove(0),
        })
    }
    /// A saved object's 404 is NOT an empty collection and must never create a
    /// replacement object. Only the explicit generated-ID flow may create.
    pub async fn read(
        &self,
        id: &str,
        collection: &str,
        cancel: &CancellationToken,
    ) -> HttpResult<RemoteRead> {
        if !opaque(collection) {
            return Err(TransportError::Configuration);
        }
        tokio::select! { biased;
            _ = cancel.cancelled() => Err(TransportError::Cancelled),
            result = self.read_inner(id, collection) => result,
        }
    }
    /// A 404 is meaningful only for the same previously generated ID, never
    /// for an arbitrary saved target. All present-object checks stay identical.
    pub async fn read_reserved(
        &self,
        reserved: &ReservedObject,
        collection: &str,
        cancel: &CancellationToken,
    ) -> HttpResult<RemoteRead> {
        if !opaque(collection) {
            return Err(TransportError::Configuration);
        }
        tokio::select! { biased;
            _ = cancel.cancelled() => Err(TransportError::Cancelled),
            result = self.read_inner_with_missing(reserved.id(), collection, true) => result,
        }
    }
    async fn read_inner(&self, id: &str, collection: &str) -> HttpResult<RemoteRead> {
        self.read_inner_with_missing(id, collection, false).await
    }
    async fn read_inner_with_missing(
        &self,
        id: &str,
        collection: &str,
        allow_missing: bool,
    ) -> HttpResult<RemoteRead> {
        for _ in 0..3 {
            let mut url = Self::object_url(&self.api, id)?;
            url.query_pairs_mut().append_pair("fields", FIELDS);
            let mut metadata = self
                .request(self.client.get(url))?
                .send()
                .await
                .map_err(|_| TransportError::Network)?;
            if metadata.status() == StatusCode::NOT_FOUND && allow_missing {
                return Ok(RemoteRead::Missing);
            }
            read_status(&metadata)?;
            let etag = webdav::response_tag(&metadata)?;
            let file: Metadata = json(&mut metadata).await?;
            let file = file.checked()?;
            if file.id != id || file.collection != collection {
                return Err(TransportError::Response);
            }
            let mut media = Self::object_url(&self.api, id)?;
            media.query_pairs_mut().append_pair("alt", "media");
            let mut response = self
                .request(self.client.get(media))?
                .header(header::IF_MATCH, etag.header_value())
                .send()
                .await
                .map_err(|_| TransportError::Network)?;
            if response.status() == StatusCode::PRECONDITION_FAILED {
                continue;
            }
            read_status(&response)?;
            let mut raw = drive_oauth::bounded(&mut response, MAX_ENCRYPTED_BYTES)
                .await
                .map_err(|_| TransportError::Response)?;
            if raw.len() as u64 != file.bytes {
                return Err(TransportError::Response);
            }
            return Ok(RemoteRead::Present {
                etag,
                ciphertext: std::mem::take(&mut *raw),
            });
        }
        Err(TransportError::Response)
    }
    pub async fn publish(
        &self,
        id: &str,
        upload: PendingUpload,
        cancel: &CancellationToken,
    ) -> HttpResult<PutResponse> {
        if !matches!(upload.condition(), PublicationCondition::Match(_)) {
            return Err(TransportError::Configuration);
        }
        let PublicationCondition::Match(tag) = upload.condition() else {
            return Err(TransportError::Configuration);
        };
        // Recheck the selected object's identity under the ORIGINAL ETag.
        // A UI/driver ID mix-up cannot overwrite a different collection merely
        // because it happened to have an equal tag. Final PATCH still uses CAS.
        let preflight = async {
            let mut metadata_url = Self::object_url(&self.api, id)?;
            metadata_url.query_pairs_mut().append_pair("fields", FIELDS);
            let mut response = self
                .request(self.client.get(metadata_url))?
                .header(header::IF_MATCH, tag.header_value())
                .send()
                .await
                .map_err(|_| TransportError::Network)?;
            if response.status() == StatusCode::PRECONDITION_FAILED {
                return Ok(false);
            }
            read_status(&response)?;
            if webdav::response_tag(&response)? != *tag {
                return Ok(false);
            }
            let metadata: Metadata = json(&mut response).await?;
            let metadata = metadata.checked()?;
            if metadata.id != id || metadata.collection != upload.collection() {
                return Err(TransportError::Response);
            }
            Ok(true)
        };
        let matches = tokio::select! { biased;
            _ = cancel.cancelled() => return Err(TransportError::Cancelled),
            result = preflight => result?,
        };
        if !matches {
            return Ok(PutResponse::PreconditionFailed);
        }
        let mut url = Self::object_url(&self.upload, id)?;
        url.query_pairs_mut()
            .append_pair("uploadType", "media")
            .append_pair("fields", "id");
        let request = self
            .request(self.client.patch(url))?
            .header(header::IF_MATCH, tag.header_value())
            .header(header::CONTENT_TYPE, MIME)
            .body(upload.ciphertext().to_vec());
        self.send_publication(request, id, upload, cancel).await
    }
    /// Exactly one explicit create with a pre-generated ID and encrypted body.
    /// No empty remote placeholder or cleartext configuration is uploaded.
    pub async fn create(
        &self,
        reserved: ReservedObject,
        upload: PendingUpload,
        cancel: &CancellationToken,
    ) -> HttpResult<PutResponse> {
        if !matches!(upload.condition(), PublicationCondition::CreateOnly) {
            return Err(TransportError::Configuration);
        }
        let collection = upload.collection();
        let id = reserved.id;
        let metadata = serde_json::to_vec(&serde_json::json!({
            "id": id, "name": name(collection), "mimeType": MIME,
            "parents": ["appDataFolder"], "appProperties": properties(collection),
        }))
        .map_err(|_| TransportError::Configuration)?;
        let boundary = format!("hspsync{:032x}", rand::random::<u128>());
        if upload
            .ciphertext()
            .windows(boundary.len())
            .any(|s| s == boundary.as_bytes())
        {
            return Err(TransportError::Configuration);
        }
        let mut body =
            format!("--{boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n")
                .into_bytes();
        body.extend_from_slice(&metadata);
        body.extend_from_slice(
            format!("\r\n--{boundary}\r\nContent-Type: {MIME}\r\n\r\n").as_bytes(),
        );
        body.extend_from_slice(upload.ciphertext());
        body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
        let mut url = self.upload.clone();
        url.query_pairs_mut()
            .append_pair("uploadType", "multipart")
            .append_pair("fields", "id");
        let request = self
            .request(self.client.post(url))?
            .header(header::IF_NONE_MATCH, "*")
            .header(
                header::CONTENT_TYPE,
                format!("multipart/related; boundary={boundary}"),
            )
            .body(body);
        self.send_publication(request, &id, upload, cancel).await
    }
    async fn send_publication(
        &self,
        request: RequestBuilder,
        id: &str,
        upload: PendingUpload,
        cancel: &CancellationToken,
    ) -> HttpResult<PutResponse> {
        tokio::select! { biased;
            _ = cancel.cancelled() => Err(TransportError::WriteUnknown),
            result = async {
                let mut response = request.send().await.map_err(|_| TransportError::WriteUnknown)?;
                match response.status() {
                    StatusCode::PRECONDITION_FAILED | StatusCode::CONFLICT => Ok(PutResponse::PreconditionFailed),
                    StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => Err(TransportError::Denied),
                    StatusCode::OK | StatusCode::CREATED => {
                        let tag = webdav::response_tag(&response).map_err(|_| TransportError::WriteUnknown)?;
                        #[derive(Deserialize)]
                        #[serde(deny_unknown_fields)]
                        struct Published { id: String }
                        let ack: Published = json(&mut response).await.map_err(|_| TransportError::WriteUnknown)?;
                        if ack.id != id { return Err(TransportError::WriteUnknown); }
                        Ok(PutResponse::Confirmed(upload.acknowledge(tag)))
                    },
                    _ => Err(TransportError::WriteUnknown),
                }
            } => result,
        }
    }
}
