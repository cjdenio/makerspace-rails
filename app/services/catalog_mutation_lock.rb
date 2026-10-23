# Shared by both physical tools and groups: uniqueness spans two collections.
class CatalogMutationLock
  # Long bulk transactions must not outlive the catalog lease. One key, no
  # member lock chain. A crashed worker requires explicit orphan-lock recovery.
  def self.with_persistent(shop_id, &block)
    CheckoutMutationLock.with(member_id: 'catalog', tool_id: shop_id, persistent: true, &block)
  end

  def self.with(shop_ids, &block)
    ids = Array(shop_ids).compact.map(&:to_s).uniq.sort
    return yield if ids.empty?

    CheckoutMutationLock.with(member_id: "catalog", tool_id: ids.first) do
      with(ids.drop(1), &block)
    end
  end
end
