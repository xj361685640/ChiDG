module mod_grid
#include <messenger.h>
    use mod_kinds,          only: rk,ik
    use mod_constants,      only: ONE, TWO, ZERO, SPACEDIM
    use mod_polynomial,     only: polynomialVal
    use type_densematrix,   only: densematrix_t
    use mod_inv
    implicit none

    !
    ! coordinate mapping matrices
    !
    integer(ik),         parameter      :: nmap = 4
    type(densematrix_t), save,  target  :: ELEM_MAP(nmap)  !< array of matrices

    logical :: uninitialized = .true.

contains



    !>  Call grid initialization routines. This is called by chidg%init('env'). So, should
    !!  not need to call this explicity.
    !!
    !!      - calls computes_element_mappings
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !!
    !----------------------------------------------------------------------------------------------------
    subroutine initialize_grid()

        if (uninitialized) then
            call compute_element_mappings()
        end if

        uninitialized = .false.

    end subroutine initialize_grid
    !****************************************************************************************************








    !>  Compute matrix to convert element discrete coordinates to modal coordinates. Initializes the
    !!  array of denseblock matrices in ELEM_MAP.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !---------------------------------------------------------------------------------------------------
    subroutine compute_element_mappings()
        use type_point, only: point_t

        type(point_t),  allocatable :: nodes(:)
        real(rk),       allocatable :: xi(:),eta(:),zeta(:)
        integer(ik)                 :: npts_1d(4), npts_2d(4), npts_3d(4)
        integer(ik)                 :: ierr, imap, iterm, inode, ipt
        integer(ik)                 :: ixi,  ieta, izeta

        !
        ! Mapping order
        ! [linear, quadratic, cubic, quartic]
        !
        npts_1d = [2,3,4,5]                 ! Number of points defining an edge
        npts_2d = npts_1d*npts_1d           ! Number of points defining an element in 2D
        npts_3d = npts_1d*npts_1d*npts_1d   ! Number of points defining an element in 3D


        !
        ! Loop through and compute mapping for different element types
        !
        do imap = 1,nmap

            !
            ! Initialize mapping for reference element.
            !
            if ( SPACEDIM == 3 ) then
                call elem_map(imap)%init(npts_3d(imap),npts_3d(imap),0)
            else if ( SPACEDIM == 2 ) then
                call elem_map(imap)%init(npts_2d(imap),npts_2d(imap),0)
            end if



            !
            ! Allocate storage for nodes and coordinates.
            !
            if ( SPACEDIM == 3 ) then
                allocate(nodes(npts_3d(imap)),  &
                         xi(npts_1d(imap)),     &
                         eta(npts_1d(imap)),    &
                         zeta(npts_1d(imap)), stat=ierr)
                if (ierr /= 0) call AllocationError

            else if ( SPACEDIM == 2 ) then
                allocate(nodes(npts_2d(imap)),  &
                         xi(npts_1d(imap)),     &
                         eta(npts_1d(imap)),    &
                         zeta(npts_1d(imap)), stat=ierr)
                if (ierr /= 0) call AllocationError

            end if


            !
            ! Compute 1d point coordinates in each direction
            !
            do ipt = 1,npts_1d(imap)
                xi(ipt)   = -ONE + (real(ipt,rk)-ONE)*(TWO/(real(npts_1d(imap),rk)-ONE))
                eta(ipt)  = -ONE + (real(ipt,rk)-ONE)*(TWO/(real(npts_1d(imap),rk)-ONE))
                zeta(ipt) = -ONE + (real(ipt,rk)-ONE)*(TWO/(real(npts_1d(imap),rk)-ONE))
            end do


            !
            ! Set up reference mesh nodes in each direction
            !
            inode = 1
            if ( SPACEDIM == 3 ) then

                do izeta = 1,npts_1d(imap)
                    do ieta = 1,npts_1d(imap)
                        do ixi = 1,npts_1d(imap)
                            call nodes(inode)%set(xi(ixi), eta(ieta), zeta(izeta))
                            inode = inode + 1
                        end do
                    end do
                end do

            else if ( SPACEDIM == 2 ) then

                do ieta = 1,npts_1d(imap)
                    do ixi = 1,npts_1d(imap)
                        call nodes(inode)%set(xi(ixi), eta(ieta), ZERO)
                        inode = inode + 1
                    end do
                end do

            else
                call chidg_signal(FATAL,"mod_grid::compute_elements_mappings - Invalid SPACEDIM")

            end if


            !
            ! Compute the values of each mapping term at each mesh point
            !
            if ( SPACEDIM == 3 ) then
                do iterm = 1,npts_3d(imap)
                    do inode = 1,npts_3d(imap)
                        ELEM_MAP(imap)%mat(inode,iterm) = polynomialVal(3,npts_3d(imap),iterm,nodes(inode))
                    end do
                end do

            else if ( SPACEDIM == 2 ) then
                do iterm = 1,npts_2d(imap)
                    do inode = 1,npts_2d(imap)
                        ELEM_MAP(imap)%mat(inode,iterm) = polynomialVal(2,npts_2d(imap),iterm,nodes(inode))
                    end do
                end do

            end if 

            
            !
            ! Invert matrix so that it can multiply a vector of
            ! element points to compute the mode amplitudes of the x,y mappings
            !
            elem_map(imap)%mat = inv(ELEM_MAP(imap)%mat)


            !
            ! Dellocate variables for next iteration in loop
            !
            deallocate(nodes, xi, eta, zeta)

        end do


    end subroutine compute_element_mappings
    !**********************************************************************************************************








end module mod_grid
