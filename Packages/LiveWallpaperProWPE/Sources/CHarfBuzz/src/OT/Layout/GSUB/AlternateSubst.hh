#ifndef OT_LAYOUT_GSUB_ALTERNATESUBST_HH
#define OT_LAYOUT_GSUB_ALTERNATESUBST_HH

#include "AlternateSubstFormat1.hh"
#include "Common.hh"

namespace OT {
namespace Layout {
namespace GSUB_impl {

struct AlternateSubst
{
  protected:
  union {
  struct { HBUINT16 v; }		format;         /* Format identifier */
  AlternateSubstFormat1_2<SmallTypes>	format1;
#ifndef HB_NO_BEYOND_64K
  AlternateSubstFormat1_2<MediumTypes>	format2;
#endif
  } u;
  public:

  template <typename context_t, typename ...Ts>
  typename context_t::return_t dispatch (context_t *c, Ts&&... ds) const
  {
    if (unlikely (!c->may_dispatch (this, &u.format.v))) return c->no_dispatch_return_value ();
    TRACE_DISPATCH (this, u.format.v);
    switch (u.format.v) {
    case 1: return_trace (c->dispatch (u.format1, std::forward<Ts> (ds)...));
#ifndef HB_NO_BEYOND_64K
    case 2: return_trace (c->dispatch (u.format2, std::forward<Ts> (ds)...));
#endif
    default:return_trace (c->default_return_value ());
    }
  }

  /* TODO subset() should choose format. */

};

}
}
}

#endif  /* OT_LAYOUT_GSUB_ALTERNATESUBST_HH */
