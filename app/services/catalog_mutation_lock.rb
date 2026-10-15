# Shared by both physical tools and groups: uniqueness spans two collections.
class CatalogMutationLock
  def self.with(shop_ids, &block)
    ids = Array(shop_ids).compact.map(&:to_s).uniq.sort
    return yield if ids.empty?

    CheckoutMutationLock.with(member_id: "catalog", tool_id: ids.first) do
      with(ids.drop(1), &block)
    end
  end
end
