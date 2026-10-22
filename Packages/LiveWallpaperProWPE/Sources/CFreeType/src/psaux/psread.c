/****************************************************************************
 *
 * psread.c
 *
 *   Adobe's code for stream handling (body).
 *
 * Copyright 2007-2013 Adobe Systems Incorporated.
 *
 * This software, and all works of authorship, whether in source or
 * object code form as indicated by the copyright notice(s) included
 * herein (collectively, the "Work") is made available, and may only be
 * used, modified, and distributed under the FreeType Project License,
 * LICENSE.TXT.  Additionally, subject to the terms and conditions of the
 * FreeType Project License, each contributor to the Work hereby grants
 * to any individual or legal entity exercising permissions granted by
 * the FreeType Project License and this section (hereafter, "You" or
 * "Your") a perpetual, worldwide, non-exclusive, no-charge,
 * royalty-free, irrevocable (except as stated in this section) patent
 * license to make, have made, use, offer to sell, sell, import, and
 * otherwise transfer the Work, where such license applies only to those
 * patent claims licensable by such contributor that are necessarily
 * infringed by their contribution(s) alone or by combination of their
 * contribution(s) with the Work to which such contribution(s) was
 * submitted.  If You institute patent litigation against any entity
 * (including a cross-claim or counterclaim in a lawsuit) alleging that
 * the Work or a contribution incorporated within the Work constitutes
 * direct or contributory patent infringement, then any patent licenses
 * granted to You under this License for that Work shall terminate as of
 * the date such litigation is filed.
 *
 * By using, modifying, or distributing the Work you indicate that you
 * have read and understood the terms and conditions of the
 * FreeType Project License as well as those provided in this section,
 * and you accept them fully.
 *
 */


#include "psft.h"
#include <freetype/internal/ftdebug.h>

#include "psglue.h"

#include "pserror.h"


  /* Region Buffer                                      */
  /*                                                    */
  /* Can be constructed from a copied buffer managed by */
  /* `FCM_getDatablock'.                                */
  /* Reads bytes with check for end of buffer.          */

  /* reading past the end of the buffer sets error and returns zero */
  FT_LOCAL_DEF( CF2_Int )
  cf2_buf_readByte( CF2_Buffer  buf )
  {
    if ( buf->ptr < buf->end )
    {
      return *(buf->ptr)++;
    }
    else
    {
      CF2_SET_ERROR( buf->error, Invalid_Stream_Operation );
      return 0;
    }
  }


  /* note: end condition can occur without error */
  FT_LOCAL_DEF( FT_Bool )
  cf2_buf_isEnd( CF2_Buffer  buf )
  {
    return FT_BOOL( buf->ptr >= buf->end );
  }


/* END */
