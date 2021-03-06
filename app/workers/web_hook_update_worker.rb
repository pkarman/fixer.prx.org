# encoding: utf-8

require 'base_worker'

class WebHookUpdateWorker < BaseWorker

  queue_as :fixer_update

  def perform(log)
    web_hook = nil
    ActiveRecord::Base.connection_pool.with_connection do
      log = JSON.parse(log).with_indifferent_access
      web_hook_log = log[:web_hook].with_indifferent_access
      web_hook = WebHook.find_by_id(web_hook_log[:id])
      return unless web_hook

      web_hook.update_completed(web_hook_log[:complete])
    end
    web_hook
  end
end
