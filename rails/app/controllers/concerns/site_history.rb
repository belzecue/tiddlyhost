module SiteHistory
  extend ActiveSupport::Concern

  included do
    before_action :require_site_history_or_preview_enabled!,
      only: [:history]

    before_action :require_site_history_enabled!,
      only: [:view_version, :download_version, :restore_version, :discard_version]

    before_action :set_blob_id,
      only: [:view_version, :download_version, :restore_version, :discard_version]
  end

  def history
    @current_blob_id = @site.blob.id
    @saved_version_count = @site.saved_version_count
    @keep_count = @site.keep_count
  end

  def view_version
    # (Not sure what's best for is_logged_in here but it probably doesn't matter much)
    render html: @site.html_content_for_blob_id(@blob_id, is_logged_in: true).html_safe
  end

  def download_version
    download_html_content(@site.download_content_for_blob_id(@blob_id), @site.name)
  end

  def restore_version
    @site.content_upload(@site.file_download(@blob_id))
    redirect_to action: :history
  end

  def discard_version
    # It's not generally recommended to purge blobs in the foreground in case the
    # back end is flaky or slow, but let's try this anyway and see how it goes.
    @site.specific_saved_content_file(@blob_id).purge
    redirect_to action: :history
  end

  private

  def require_site_history_or_preview_enabled!
    require_condition!(feature_enabled?(:site_history) || feature_enabled?(:site_history_preview))
  end

  def require_site_history_enabled!
    require_condition!(feature_enabled?(:site_history))
  end

  def set_blob_id
    @blob_id = params[:blob_id]
  end
end
